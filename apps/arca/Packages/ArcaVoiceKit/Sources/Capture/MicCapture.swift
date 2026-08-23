import Foundation
import AVFoundation
import ArcaVoiceCore

/// Microphone capture via AVAudioEngine — works on macOS and iOS.
///
/// Self-healing by design. A tap installed once and never touched again is not a
/// recording: a phone call, Siri, a headset unplug, a Bluetooth handoff, or a
/// media-services reset each tear the engine's graph out from under it, and the
/// callback simply stops firing while the UI keeps counting. This class watches
/// for every one of those events, rebuilds the session/graph/tap into the *same*
/// output file, and reports what it could not fix through `onHealth` so the
/// recording surface can stop pretending.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var writer: ChannelWriter?
    #if os(macOS)
    private var previousDefaultInput: AudioDeviceID?
    #endif

    /// Every engine/tap mutation runs here — interruption notifications arrive
    /// on whatever thread posted them, and two overlapping rebuilds would race.
    private let queue = DispatchQueue(label: "com.thezone.arca.miccapture")
    private var observers: [NSObjectProtocol] = []
    private var onBuffer: ((CapturedBuffer) -> Void)?
    private var onHealth: ((CaptureHealth) -> Void)?
    /// True between `start()` and `stop()` — recovery only runs inside that window.
    private var isRunning = false
    private var recoveryAttempts = 0
    private var lastReported: CaptureHealth?
    /// Collapses bursts of notifications (an unplug posts route-change *and*
    /// configuration-change) into one rebuild.
    private var recoveryGeneration = 0

    /// ~4.5 minutes of retrying before declaring the recording dead. The budget
    /// resets on every fresh event, so a 20-minute phone call still resumes:
    /// its `.ended` interruption arms a brand-new budget.
    private static let maxRecoveryAttempts = 20
    private static let maxRetryDelay: TimeInterval = 15

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(directory: URL,
               onBuffer: @escaping (CapturedBuffer) -> Void,
               onHealth: @escaping (CaptureHealth) -> Void = { _ in }) throws {
        self.onBuffer = onBuffer
        self.onHealth = onHealth
        #if os(iOS)
        AudioSessionArbiter.claimForRecording()
        do {
            try activateSession()
        } catch {
            AudioSessionArbiter.releaseRecording()
            throw error
        }
        #endif

        let input = engine.inputNode
        #if os(macOS)
        // A Bluetooth speaker as default input drags the whole system into
        // 16kHz HFP call mode the moment we record (music turns to walkie-
        // talkie) and its far-away mic records garbage. Pin the engine's
        // input unit to the built-in mic (system default switch alone gets
        // reverted by macOS's BT preference), then reset so the node's
        // format reflects the real device.
        if let builtin = Self.builtInInputDevice(),
           Self.defaultInputTransport() == kAudioDeviceTransportTypeBluetooth {
            previousDefaultInput = Self.currentDefaultInput()
            if !Self.setDefaultInput(builtin) { previousDefaultInput = nil }
            var deviceID = builtin
            if let unit = input.audioUnit {
                let err = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
                CaptureTrace.log("mic: pin input unit to built-in → \(err == noErr ? "ok" : "err \(err)")")
            }
            engine.reset()
            Thread.sleep(forTimeInterval: 0.25) // let CoreAudio settle the switch
        }
        #endif
        let format = input.outputFormat(forBus: 0)
        CaptureTrace.log("mic: input format \(format.sampleRate)Hz x\(format.channelCount)")
        guard format.sampleRate > 0 else {
            restoreDefaultInputIfNeeded()
            releaseSessionClaim()
            throw CaptureError.formatUnavailable
        }

        // Created once and reused across every recovery: the file the user is
        // recording into must survive an interruption, not restart. The writer
        // resamples whatever format the hardware comes back with into the file's
        // own format, so a route change mid-recording is not fatal.
        let writer = try ChannelWriter(channel: .microphone, directory: directory, sourceFormat: format)
        self.writer = writer

        do {
            try startEngine()
        } catch {
            restoreDefaultInputIfNeeded()
            releaseSessionClaim()
            throw error
        }
        isRunning = true
        report(.capturing)
        registerObservers()
    }

    // MARK: - Engine lifecycle

    /// Installs the tap against the input's *current* format and starts the
    /// engine. Safe to call repeatedly — an existing tap is removed first.
    private func startEngine() throws {
        guard let writer else { throw CaptureError.formatUnavailable }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError.formatUnavailable }
        input.removeTap(onBus: 0)
        let handler = onBuffer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let captured = writer.write(buffer) {
                handler?(captured)
            }
        }
        engine.prepare()
        try engine.start()
    }

    #if os(iOS)
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }
    #endif

    private func releaseSessionClaim() {
        #if os(iOS)
        AudioSessionArbiter.releaseRecording()
        #endif
    }

    // MARK: - Interruption / route-change recovery

    private func registerObservers() {
        let center = NotificationCenter.default
        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                .contains(.shouldResume)
            self?.handleInterruption(began: type == .began, shouldResume: shouldResume)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            self?.handleRouteChange(reason)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // Everything — session, engine, graph — is invalid after this.
            self?.scheduleRecovery(
                reason: "오디오 시스템이 재시작됐어요 — 녹음을 다시 연결하는 중이에요",
                resetEngine: true)
        })
        #endif
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // The engine drops its render graph when the hardware format changes;
            // the tap installed against the old format never fires again.
            self?.scheduleRecovery(
                reason: "오디오 장치가 바뀌었어요 — 녹음을 다시 연결하는 중이에요",
                resetEngine: true)
        })
    }

    #if os(iOS)
    private func handleInterruption(began: Bool, shouldResume: Bool) {
        queue.async { [self] in
            guard isRunning else { return }
            if began {
                CaptureTrace.log("mic: interruption began")
                engine.pause()
                report(.interrupted(
                    reason: "다른 앱이 마이크를 쓰고 있어요 (통화·Siri 등). 끝나면 같은 파일에 이어서 녹음해요."))
            } else {
                // `.shouldResume` is advisory for playback; a recording always
                // tries, because the cost of not trying is losing the meeting.
                CaptureTrace.log("mic: interruption ended (shouldResume=\(shouldResume))")
                recoveryAttempts = 0
                recovery(resetEngine: false)
            }
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override,
             .categoryChange, .routeConfigurationChange:
            scheduleRecovery(
                reason: "오디오 경로가 바뀌었어요 — 녹음을 다시 연결하는 중이에요",
                resetEngine: false)
        default:
            break
        }
    }
    #endif

    /// Debounced entry point: several notifications describing one physical
    /// event collapse into a single rebuild.
    private func scheduleRecovery(reason: String, resetEngine: Bool) {
        queue.async { [self] in
            guard isRunning else { return }
            recoveryGeneration += 1
            let generation = recoveryGeneration
            recoveryAttempts = 0
            report(.interrupted(reason: reason))
            queue.asyncAfter(deadline: .now() + 0.3) { [self] in
                guard generation == recoveryGeneration else { return }
                recovery(resetEngine: resetEngine)
            }
        }
    }

    /// Rebuilds session → engine → tap. Must only run on `queue`.
    private func recovery(resetEngine: Bool) {
        guard isRunning else { return }
        #if os(iOS)
        do {
            try activateSession()
        } catch {
            retryRecovery(resetEngine: resetEngine, error: error)
            return
        }
        #endif
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        if resetEngine { engine.reset() }
        do {
            try startEngine()
            recoveryAttempts = 0
            report(.capturing)
            CaptureTrace.log("mic: capture recovered, still writing to the same file")
        } catch {
            retryRecovery(resetEngine: resetEngine, error: error)
        }
    }

    private func retryRecovery(resetEngine: Bool, error: Error) {
        recoveryAttempts += 1
        guard recoveryAttempts <= Self.maxRecoveryAttempts else {
            CaptureTrace.log("mic: recovery gave up after \(recoveryAttempts) tries — \(error)")
            report(.stopped(
                reason: "마이크를 다시 열 수 없어 녹음을 여기서 마무리했어요 (\(error.localizedDescription))"))
            return
        }
        let delay = min(Self.maxRetryDelay, pow(2, Double(recoveryAttempts - 1)) * 0.5)
        CaptureTrace.log("mic: recovery attempt \(recoveryAttempts) failed (\(error)), retrying in \(delay)s")
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            recovery(resetEngine: resetEngine)
        }
    }

    private func report(_ health: CaptureHealth) {
        guard lastReported != health else { return }
        lastReported = health
        onHealth?(health)
    }

    private func restoreDefaultInputIfNeeded() {
        #if os(macOS)
        if let previous = previousDefaultInput {
            _ = Self.setDefaultInput(previous)
            previousDefaultInput = nil
            CaptureTrace.log("mic: default input restored")
        }
        #endif
    }

    #if os(macOS)
    private static func currentDefaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func setDefaultInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = deviceID
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr
    }

    private static func defaultInputTransport() -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr else { return 0 }
        var transport = UInt32(0)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &size, &transport)
        return transport
    }

    private static func builtInInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else { return nil }
        for device in devices {
            var transport = UInt32(0)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil,
                                             &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            // Must actually have input channels.
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamsSize = UInt32(0)
            guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil,
                                                 &streamsSize) == noErr, streamsSize > 0 else { continue }
            return device
        }
        return nil
    }
    #endif

    func stop() -> (url: URL, duration: TimeInterval)? {
        // Close the recovery window first: a route change firing during teardown
        // must not resurrect the engine after the file has been handed off.
        queue.sync {
            isRunning = false
            recoveryGeneration += 1
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        restoreDefaultInputIfNeeded()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        releaseSessionClaim()
        onBuffer = nil
        onHealth = nil
        guard let writer else { return nil }
        return (writer.fileURL, writer.elapsed)
    }
}

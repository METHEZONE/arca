import Accelerate
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

    /// Dead-input watchdog. A real microphone never delivers exact zeros — even
    /// a muted room has a noise floor — so a run of digitally silent buffers
    /// means the device behind the engine isn't a microphone at all: a virtual
    /// loopback (BlackHole, Zoom/Teams audio device) nobody is feeding, or an
    /// aggregate with no live input. A 66-minute call once recorded 3,993 s of
    /// zeros this way and nobody knew until the transcript came back empty.
    private var silentSeconds: Double = 0
    private var silenceEscalated = false
    private var silenceNotified = false
    private var pinnedToBuiltIn = false
    private static let digitalSilenceThreshold: Float = 1e-6
    private static let silenceGrace: Double = 6

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
        CaptureTrace.log("mic: start — permission granted")
        #if os(iOS)
        AudioSessionArbiter.claimForRecording()
        CaptureTrace.log("mic: session claimed")
        do {
            try activateSession()
            CaptureTrace.log("mic: session activated")
        } catch {
            AudioSessionArbiter.releaseRecording()
            CaptureTrace.log("mic: session activation failed — \(error)")
            throw error
        }
        #endif

        let input = engine.inputNode
        #if os(macOS)
        // A Bluetooth speaker as default input drags the whole system into
        // 16kHz HFP call mode the moment we record (music turns to walkie-
        // talkie) and its far-away mic records garbage. A virtual device
        // (BlackHole, ZoomAudioDevice, Teams Audio) or an aggregate as default
        // input is worse: nothing feeds it, so it records exact digital
        // silence for the whole meeting. In both cases pin the engine's input
        // unit to the built-in mic (system default switch alone gets reverted
        // by macOS's BT preference), then reset so the node's format reflects
        // the real device.
        let transport = Self.defaultInputTransport()
        CaptureTrace.log("mic: default input '\(Self.currentDefaultInput().map(Self.deviceName) ?? "?")' transport \(Self.transportLabel(transport))")
        if Self.transportNeedsBuiltInPin(transport) {
            pinToBuiltIn()
        }
        #endif
        var format = input.outputFormat(forBus: 0)
        #if os(iOS)
        // Right after `setActive(true)` the route is not always settled yet —
        // the hardware format can read 0Hz for a beat, especially on a cold
        // start (first recording after granting mic permission, or right after
        // a route change). macOS's Bluetooth-pin path already knows to give
        // CoreAudio a moment (see `Thread.sleep` above); iOS needs the same
        // grace instead of failing the whole recording on a transient read.
        var settleAttempts = 0
        while format.sampleRate == 0, settleAttempts < 5 {
            settleAttempts += 1
            Thread.sleep(forTimeInterval: 0.05)
            format = input.outputFormat(forBus: 0)
        }
        if settleAttempts > 0 {
            CaptureTrace.log("mic: input format settled after \(settleAttempts) retries")
        }
        #endif
        CaptureTrace.log("mic: input format \(format.sampleRate)Hz x\(format.channelCount)")
        guard format.sampleRate > 0 else {
            CaptureTrace.log("mic: input format never settled — giving up")
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
            CaptureTrace.log("mic: engine start failed — \(error)")
            restoreDefaultInputIfNeeded()
            releaseSessionClaim()
            throw error
        }
        isRunning = true
        report(.capturing)
        registerObservers()
        CaptureTrace.log("mic: engine started — capturing")
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
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            if let captured = writer.write(buffer) {
                handler?(captured)
            }
            self?.observeLevel(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: - Dead-input watchdog

    /// Runs on the render thread: one peak scan per buffer, nothing else.
    private func observeLevel(_ buffer: AVAudioPCMBuffer) {
        guard !silenceEscalated, let channels = buffer.floatChannelData else { return }
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0 else { return }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &channelPeak, frames)
            peak = max(peak, channelPeak)
        }
        if peak > Self.digitalSilenceThreshold {
            silentSeconds = 0
            if silenceNotified {
                silenceNotified = false
                queue.async { [self] in report(.capturing) }
            }
            return
        }
        silentSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        guard silentSeconds >= Self.silenceGrace else { return }
        silenceEscalated = true
        queue.async { [self] in handleDeadInput() }
    }

    /// Must only run on `queue`. First strike: switch to the built-in mic and
    /// rebuild into the same file. Second strike (already built-in, still
    /// zeros): tell the user, once, and keep recording — it might be a hardware
    /// mute that they can lift.
    private func handleDeadInput() {
        guard isRunning else { return }
        #if os(macOS)
        if !pinnedToBuiltIn, Self.builtInInputDevice() != nil {
            let previousName = Self.currentDefaultInput().map(Self.deviceName) ?? "?"
            CaptureTrace.log("mic: \(Int(Self.silenceGrace))s of digital silence from '\(previousName)' — switching to built-in")
            report(.interrupted(
                reason: "'\(previousName)'에서 소리가 전혀 안 들어와서 내장 마이크로 바꿨어요"))
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            pinToBuiltIn()
            silentSeconds = 0
            silenceEscalated = false
            recovery(resetEngine: true)
            return
        }
        #endif
        guard !silenceNotified else { return }
        silenceNotified = true
        silentSeconds = 0
        silenceEscalated = false
        CaptureTrace.log("mic: still digital silence on the active input — notifying")
        report(.interrupted(
            reason: "마이크에서 소리가 들어오지 않아요 — 시스템 설정 › 사운드 › 입력을 확인해주세요"))
    }

    #if os(macOS)
    /// Points the engine's input unit at the built-in microphone (and makes it
    /// the system default for the duration, restored on stop).
    private func pinToBuiltIn() {
        guard let builtin = Self.builtInInputDevice() else { return }
        if previousDefaultInput == nil {
            previousDefaultInput = Self.currentDefaultInput()
            if !Self.setDefaultInput(builtin) { previousDefaultInput = nil }
        }
        var deviceID = builtin
        if let unit = engine.inputNode.audioUnit {
            let err = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            CaptureTrace.log("mic: pin input unit to built-in → \(err == noErr ? "ok" : "err \(err)")")
        }
        engine.reset()
        Thread.sleep(forTimeInterval: 0.25) // let CoreAudio settle the switch
        pinnedToBuiltIn = true
    }

    private static func transportNeedsBuiltInPin(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
            || transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
    }

    private static func transportLabel(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeUSB: return "usb"
        default: return String(transport)
        }
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        AudioObjectID(deviceID).readName()
    }
    #endif

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
        silentSeconds = 0
        silenceEscalated = false
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

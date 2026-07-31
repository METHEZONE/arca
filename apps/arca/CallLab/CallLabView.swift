import SwiftUI
import Combine
import ArcaVoiceKit

/// The call screen plus a live quality HUD.
///
/// The HUD is the point. "통화가 지지직거린다" is unfalsifiable; MOS 2.8 with 4%
/// loss and 180ms of buffer is something you can act on. Every number here is
/// measured on this device from real packets — none of it is modelled.
struct CallLabView: View {
    @AppStorage("calllab.signalingURL") private var signalingURL = "wss://call.thezonebio.com/call"
    @AppStorage("calllab.relayHost") private var relayHost = "call.thezonebio.com"
    @AppStorage("calllab.relayPort") private var relayPort = 8081
    @AppStorage("calllab.codec") private var codecRaw = CallCodecKind.aacELD.rawValue
    @AppStorage("calllab.fec") private var useFEC = true
    @AppStorage("calllab.record") private var recordAudio = true

    @State private var session: CallSession?
    @State private var roomCode = ""
    @State private var side: CallSide = .caller
    @State private var showsSettings = false
    @State private var tick = Date()

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    stateBanner
                    if let session, session.state.isLive {
                        qualityPanel(session)
                        hangUpButton
                    } else {
                        dialPanel
                    }
                    if let outcome = session?.lastOutcome, session?.state.isLive == false {
                        outcomeCard(outcome)
                    }
                }
                .padding(20)
            }
            .navigationTitle("ARCA CallLab")
            .toolbar {
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .disabled(session?.state.isLive == true)
            }
            .sheet(isPresented: $showsSettings) { settingsSheet }
        }
        .onReceive(timer) { tick = $0 }
    }

    // MARK: - Dialling

    private var dialPanel: some View {
        VStack(spacing: 14) {
            Text("같은 방 코드를 양쪽에 입력하면 연결됩니다.\n한쪽은 발신, 한쪽은 수신으로 두세요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                TextField("방 코드", text: $roomCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title2, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                Button("생성") { roomCode = CallSession.generateRoomCode() }
                    .buttonStyle(.bordered)
            }

            Picker("역할", selection: $side) {
                Text("발신 (caller)").tag(CallSide.caller)
                Text("수신 (callee)").tag(CallSide.callee)
            }
            .pickerStyle(.segmented)

            Button {
                Task { await startCall() }
            } label: {
                Label("통화 시작", systemImage: "phone.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(roomCode.trimmingCharacters(in: .whitespaces).isEmpty)

            configSummary
        }
    }

    private var configSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("릴레이", "\(relayHost):\(relayPort)")
            row("코덱", CallCodecKind(rawValue: codecRaw)?.label ?? codecRaw)
            row("이중 전송(FEC)", useFEC ? "켜짐 · 약 80kbps" : "꺼짐 · 약 40kbps")
            row("녹음", recordAudio ? "양쪽 트랙 저장" : "저장 안 함")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var hangUpButton: some View {
        Button(role: .destructive) {
            session?.hangUp()
        } label: {
            Label("통화 종료", systemImage: "phone.down.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: - State

    private struct BannerStyle {
        let text: String
        let symbol: String
        let tint: Color
    }

    /// Computed outside the ViewBuilder: a switch that assigns values is a
    /// statement, and inside a ViewBuilder the compiler would try to read it as a
    /// view-producing switch instead.
    private var bannerStyle: BannerStyle {
        switch session?.state {
        case .none, .some(.idle):
            BannerStyle(text: "대기 중", symbol: "phone", tint: .secondary)
        case .some(.waitingForPeer):
            BannerStyle(text: "상대방 기다리는 중 · 방 \(session?.roomCode ?? "")",
                        symbol: "person.badge.clock", tint: .orange)
        case .some(.connecting):
            BannerStyle(text: "연결 중", symbol: "arrow.triangle.2.circlepath", tint: .orange)
        case .some(.active):
            BannerStyle(text: "통화 중 · \(Self.duration(session?.elapsed ?? 0))",
                        symbol: "waveform", tint: .green)
        case .some(.ended(let reason)):
            BannerStyle(text: "종료 — \(reason)", symbol: "phone.down", tint: .secondary)
        }
    }

    private var stateBanner: some View {
        let style = bannerStyle
        return HStack(spacing: 8) {
            Image(systemName: style.symbol)
            Text(style.text).font(.headline)
        }
        .foregroundStyle(style.tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(style.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Quality HUD

    private func qualityPanel(_ session: CallSession) -> some View {
        let quality = session.quality
        return VStack(spacing: 16) {
            VStack(spacing: 2) {
                Text(String(format: "%.2f", quality.estimatedMOS))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Self.mosColor(quality.estimatedMOS))
                Text("MOS · \(quality.verdict)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("일반 휴대폰 통화가 대략 3.6~4.0입니다")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                metric("손실률", String(format: "%.2f%%", quality.lossRate * 100),
                       warn: quality.lossRate > 0.02)
                metric("왕복 지연", String(format: "%.0f ms", quality.roundTripMilliseconds),
                       warn: quality.roundTripMilliseconds > 200)
                metric("편도 체감 지연", String(format: "%.0f ms", quality.oneWayLatencyMilliseconds),
                       warn: quality.oneWayLatencyMilliseconds > 200)
                metric("네트워크 지터", String(format: "%.1f ms", quality.jitterMilliseconds),
                       warn: quality.jitterMilliseconds > 30)
                metric("버퍼 깊이", String(format: "%.0f ms", quality.jitterBufferMilliseconds),
                       warn: quality.jitterBufferMilliseconds > 150)
                metric("수신 / 송신", String(format: "%.0f / %.0f kbps",
                                          quality.inboundKilobitsPerSecond,
                                          quality.outboundKilobitsPerSecond),
                       warn: false)
                metric("보정된 프레임", "\(quality.concealedFrames)", warn: quality.concealedFrames > 50)
                metric("버퍼 고갈", "\(quality.underruns)", warn: quality.underruns > 0)
                metric("중복 수신(FEC 효과)", String(format: "%.0f%%", quality.duplicateRate * 100),
                       warn: false)
            }
            .font(.callout)

            if !session.isTransportReady {
                Label("미디어 소켓 연결 대기 중", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ label: String, _ value: String, warn: Bool) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(warn ? .orange : .primary)
                .gridColumnAlignment(.trailing)
        }
    }

    // MARK: - Outcome

    private func outcomeCard(_ outcome: CallOutcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("직전 통화 리포트").font(.headline)
            Text("방 \(outcome.roomCode) · \(Self.duration(outcome.duration))")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(outcome.quality.summaryLines(), id: \.self) { line in
                Text(line).font(.system(.callout, design: .monospaced))
            }
            if let recording = outcome.recording {
                Divider()
                Text("녹음 저장됨").font(.caption).bold()
                ForEach(recording.trackURLs.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                    Text("\(entry.key == "me" ? "내 목소리" : "상대 목소리"): \(entry.value.lastPathComponent)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(recording.directory.path)
                    .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Settings

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("릴레이") {
                    TextField("시그널링 URL (wss://…/call)", text: $signalingURL)
                        .autocorrectionDisabled()
                    TextField("미디어 호스트", text: $relayHost)
                        .autocorrectionDisabled()
                    Stepper("미디어 UDP 포트: \(relayPort)", value: $relayPort, in: 1...65_535)
                }
                Section("미디어") {
                    Picker("코덱", selection: $codecRaw) {
                        ForEach(CallCodecKind.allCases, id: \.rawValue) { kind in
                            Text(kind.label).tag(kind.rawValue)
                        }
                    }
                    Toggle("이중 전송으로 손실 보정", isOn: $useFEC)
                    Toggle("통화 녹음", isOn: $recordAudio)
                }
                Section {
                    Text("PCM은 압축을 하지 않아 약 770kbps를 씁니다. "
                         + "Wi-Fi에서만 쓰세요. 품질이 나쁠 때 코덱 탓인지 회선 탓인지 "
                         + "가르는 용도입니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("설정")
            .toolbar {
                Button("닫기") { showsSettings = false }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    // MARK: - Actions

    private func startCall() async {
        guard let url = URL(string: signalingURL) else { return }
        let configuration = CallConfiguration(
            signalingURL: url,
            relayHost: relayHost,
            relayPort: UInt16(clamping: relayPort),
            codec: CallCodecKind(rawValue: codecRaw) ?? .aacELD,
            forwardErrorCorrection: useFEC,
            recordsAudio: recordAudio)
        let recordingRoot = URL.applicationSupportDirectory
            .appendingPathComponent("ArcaCallLab", isDirectory: true)
        let session = CallSession(configuration: configuration, recordingRoot: recordingRoot)
        self.session = session
        await session.start(roomCode: roomCode, as: side)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func mosColor(_ mos: Double) -> Color {
        switch mos {
        case 3.6...: .green
        case 3.0..<3.6: .yellow
        default: .red
        }
    }
}

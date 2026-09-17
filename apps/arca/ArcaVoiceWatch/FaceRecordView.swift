import SwiftUI
import WatchKit

/// The whole Watch app is one living companion, and the companion is the
/// control: tap to talk with ARCA, double-tap to record a meeting, hold to
/// leave a quick voice memo. Each state is unmistakable from across the room —
/// ring colour, eyes, body — because the wrist gets a glance, not a read.
///
///   idle       no ring     life loop (blink, glance, doze, hop)
///   talking    blue ring   listening: eyes up at you · speaking: happy eyes, body bounces with the voice
///   recording  green ring  happy eyes, breathing, timer
///   memo       amber ring  wide eyes, body leans in like an ear
struct FaceRecordView: View {
    @State private var recorder = WatchRecorder()
    @State private var talk = WatchLiveTalk.shared
    @State private var transfers = WatchTransferStatus.shared
    @AppStorage("watchHaptics") private var haptics = true

    // Life-loop state
    @State private var blinkAmount: CGFloat = 1.0
    @State private var eyeOffset: CGSize = .zero
    @State private var hop: CGFloat = 0
    @State private var dozing = false
    @State private var breathing = false
    @State private var ringPulse = false
    /// Finger is down past the long-press threshold: a memo is being spoken.
    @State private var memoHolding = false

    /// Snapshot/preview hook: forces the listening face without recording.
    private let forceListening = ProcessInfo.processInfo.environment["ARCA_PREVIEW_LISTENING"] == "1"

    enum Mode: Equatable { case idle, talking, recording, memo }

    private var mode: Mode {
        if memoHolding { return .memo }
        if talk.isActive { return .talking }
        if recorder.isRecording || forceListening { return .recording }
        return .idle
    }

    private var ringColor: Color {
        switch mode {
        case .idle: return .clear
        case .talking: return Color(red: 0.35, green: 0.62, blue: 1.0)
        case .recording: return .green
        case .memo: return .orange
        }
    }

    private var speaking: Bool { mode == .talking && talk.phase == .speaking }
    private var happyEyes: Bool { mode == .recording || speaking }
    private var pulsing: Bool { mode == .recording || (mode == .talking && !speaking) }

    var body: some View {
        ZStack {
            background

            // The state boundary — nothing subtle about it: colour says what
            // ARCA is doing right now, and no ring means it isn't doing anything.
            RoundedRectangle(cornerRadius: 38)
                .strokeBorder(ringColor.opacity(mode == .idle ? 0 : (pulsing && ringPulse ? 0.35 : 0.95)),
                              lineWidth: 5)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: ringPulse)

            VStack(spacing: 12) {
                SpiritBody(
                    happy: happyEyes,
                    dozing: dozing && mode == .idle,
                    wide: mode == .memo || (mode == .talking && !speaking),
                    blinkAmount: blinkAmount,
                    eyeOffset: mode == .talking && !speaking ? CGSize(width: 0, height: -3) : eyeOffset
                )
                .frame(width: 108, height: 108)
                .scaleEffect(bodyScale)
                .rotationEffect(.degrees(mode == .memo ? 8 : 0))
                .offset(y: hop)
                .animation(.spring(duration: 0.35, bounce: 0.4), value: mode)
                .animation(.easeOut(duration: 0.08), value: talk.speakingLevel)

                captionBlock
            }
        }
        .contentShape(Rectangle())
        // Double first: SwiftUI then waits for a second tap before declaring
        // a single one, so the two never both fire.
        .onTapGesture(count: 2) { doubleTap() }
        .onTapGesture { tap() }
        .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 30) {
            beginMemo()
        } onPressingChanged: { pressing in
            if !pressing { endMemoIfHolding() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    WatchSettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .task { await lifeLoop() }
        .onChange(of: mode) { _, newMode in
            ringPulse = newMode == .recording || newMode == .talking
            if newMode != .idle {
                dozing = false
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { breathing = false }
            }
        }
    }

    private var bodyScale: CGFloat {
        switch mode {
        case .talking where speaking: return 1.0 + CGFloat(talk.speakingLevel) * 0.14
        case .recording, .talking: return breathing ? 1.06 : 1.0
        case .memo: return 1.04
        case .idle: return 1.0
        }
    }

    // MARK: - Gestures → modes

    private func tap() {
        dozing = false
        switch mode {
        case .idle:
            haptic(.click)
            Task { await talk.start() }
        case .talking:
            talk.stop()
        case .recording:
            Task { await recorder.toggle() }
        case .memo:
            break
        }
        if case .failed = talk.phase { talk.dismissFailure() }
    }

    private func doubleTap() {
        dozing = false
        switch mode {
        case .idle, .recording:
            haptic(.start)
            Task { await recorder.toggle() }
        case .talking, .memo:
            break
        }
    }

    private func beginMemo() {
        guard mode == .idle else { return }
        memoHolding = true
        haptic(.directionUp)
        Task { await recorder.start(kind: .memo) }
    }

    private func endMemoIfHolding() {
        guard memoHolding else { return }
        memoHolding = false
        // The recorder may still be spinning up if the hold was very short.
        Task {
            var waited = 0
            while !recorder.isRecording, waited < 10 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            recorder.stopAndSend()
        }
    }

    private func haptic(_ type: WKHapticType) {
        guard haptics else { return }
        WKInterfaceDevice.current().play(type)
    }

    // MARK: - Caption

    @ViewBuilder private var captionBlock: some View {
        VStack(spacing: 2) {
            switch mode {
            case .idle:
                Text(dozing ? "zzz" : L("탭 대화 · 두 번 녹음 · 꾹 메모", "Tap talk · 2× record · hold memo"))
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if case .failed(let message) = talk.phase {
                    Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(3)
                        .multilineTextAlignment(.center)
                } else {
                    transferStatusLine
                }
            case .talking:
                switch talk.phase {
                case .connecting:
                    Text(L("연결하는 중…", "Connecting…"))
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(ringColor)
                case .speaking:
                    Text(talk.caption.isEmpty ? L("말하는 중", "Speaking") : talk.caption)
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                default:
                    Text(L("듣고 있어요", "Listening"))
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(ringColor)
                        .opacity(breathing ? 0.55 : 1.0)
                }
                Text(L("탭하면 끝", "Tap to end"))
                    .font(.caption2).foregroundStyle(.tertiary)
            case .recording:
                Text(L("녹음 중", "Recording"))
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.green)
                    .opacity(breathing ? 0.55 : 1.0)
                if let startedAt = recorder.startedAt {
                    Text(startedAt, style: .timer)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.8))
                }
            case .memo:
                Text(L("듣고 있어요 — 손을 떼면 저장", "Listening — release to save"))
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if let error = recorder.errorMessage, mode != .talking {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Where the last recording is on its journey to the iPhone — the wrist
    /// shouldn't have to wonder whether a send actually happened.
    @ViewBuilder private var transferStatusLine: some View {
        if transfers.sending > 0 {
            Label(L("아이폰으로 보내는 중…", "Sending to iPhone…"), systemImage: "iphone.and.arrow.forward.outward")
                .font(.caption2)
                .foregroundStyle(.orange)
                .transition(.opacity)
        } else if transfers.awaitingSummary {
            Label(L("아이폰에 도착 — 곧 요약이 와요", "On your iPhone — summary soon"), systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        } else if transfers.sendFailed {
            Label(L("전송 실패 — 아이폰 가까이서 다시", "Send failed — try again near your iPhone"),
                  systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .transition(.opacity)
        }
    }

    private var background: some View {
        let colors: [Color]
        switch mode {
        case .idle: colors = [Color(red: 0.13, green: 0.06, blue: 0.02), .black]
        case .talking: colors = [Color(red: 0.04, green: 0.09, blue: 0.20), .black]
        case .recording: colors = [Color(red: 0.04, green: 0.18, blue: 0.11), .black]
        case .memo: colors = [Color(red: 0.20, green: 0.11, blue: 0.02), .black]
        }
        return RadialGradient(colors: colors, center: .center, startRadius: 10, endRadius: 150)
            .ignoresSafeArea()
    }

    /// Random micro-actions keep the companion alive while idle.
    private func lifeLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.4...5.0)))
            guard mode == .idle else { continue }

            switch Int.random(in: 0..<10) {
            case 0...3:
                await blink()
            case 4:
                await blink()
                try? await Task.sleep(for: .milliseconds(160))
                await blink()
            case 5, 6:
                dozing = false
                let dx = CGFloat([-7, 7].randomElement()!)
                withAnimation(.easeOut(duration: 0.3)) {
                    eyeOffset = CGSize(width: dx, height: CGFloat.random(in: -3...2))
                }
                try? await Task.sleep(for: .seconds(Double.random(in: 0.7...1.4)))
                withAnimation(.easeInOut(duration: 0.35)) { eyeOffset = .zero }
            case 7:
                dozing = false
                withAnimation(.interpolatingSpring(stiffness: 300, damping: 12)) { hop = -9 }
                try? await Task.sleep(for: .milliseconds(170))
                withAnimation(.interpolatingSpring(stiffness: 260, damping: 14)) { hop = 0 }
            case 8:
                withAnimation(.easeInOut(duration: 0.8)) { dozing = true }
                try? await Task.sleep(for: .seconds(Double.random(in: 4...7)))
                withAnimation(.easeOut(duration: 0.4)) { dozing = false }
            default:
                withAnimation(.easeInOut(duration: 0.4)) { hop = -2 }
                try? await Task.sleep(for: .milliseconds(220))
                withAnimation(.easeInOut(duration: 0.4)) { hop = 0 }
            }
        }
    }

    private func blink() async {
        guard !dozing else { return }
        withAnimation(.easeIn(duration: 0.08)) { blinkAmount = 0.08 }
        try? await Task.sleep(for: .milliseconds(110))
        withAnimation(.easeOut(duration: 0.12)) { blinkAmount = 1.0 }
    }
}

// MARK: - The spirit (canonical round orange companion)

private struct SpiritBody: View {
    let happy: Bool
    let dozing: Bool
    /// Eyes open a little wider — attention, not alarm.
    let wide: Bool
    let blinkAmount: CGFloat
    let eyeOffset: CGSize

    var body: some View {
        ZStack {
            HStack {
                Ellipse()
                    .fill(Color(red: 0.89, green: 0.2, blue: 0.1))
                    .frame(width: 20, height: 13)
                    .offset(x: 4)
                Spacer()
                Ellipse()
                    .fill(Color(red: 0.89, green: 0.2, blue: 0.1))
                    .frame(width: 20, height: 13)
                    .offset(x: -4)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.62, blue: 0.42),
                            Color(red: 0.97, green: 0.36, blue: 0.17),
                            Color(red: 0.89, green: 0.2, blue: 0.1),
                        ],
                        center: UnitPoint(x: 0.36, y: 0.3),
                        startRadius: 4, endRadius: 78))
                .padding(10)
                .shadow(color: Color(red: 0.97, green: 0.36, blue: 0.17).opacity(0.55),
                        radius: happy ? 18 : 10)

            Triangle()
                .fill(Color(red: 0.89, green: 0.2, blue: 0.1))
                .frame(width: 15, height: 13)
                .rotationEffect(.degrees(18))
                .offset(x: 20, y: -44)

            FaceEyes(happy: happy, dozing: dozing, wide: wide, blinkAmount: blinkAmount)
                .offset(eyeOffset)
        }
    }
}

private struct FaceEyes: View {
    let happy: Bool
    let dozing: Bool
    let wide: Bool
    let blinkAmount: CGFloat

    private let cream = Color(red: 1.0, green: 0.96, blue: 0.93)

    var body: some View {
        HStack(spacing: 18) {
            eye
            eye
        }
        .offset(y: 2)
    }

    @ViewBuilder private var eye: some View {
        ZStack {
            DomeShape()
                .fill(cream)
                .frame(width: 17, height: 15)
                .scaleEffect(x: wide ? 1.15 : 1, y: blinkAmount * (wide ? 1.25 : 1), anchor: .bottom)
                .opacity(happy || dozing ? 0 : 1)

            HappyArc()
                .stroke(cream, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .frame(width: 18, height: 10)
                .opacity(happy ? 1 : 0)

            SleepArc()
                .stroke(cream.opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 16, height: 8)
                .opacity(dozing && !happy ? 1 : 0)
        }
        .frame(width: 20, height: 16)
    }
}

/// Rounded-top, flat-bottom "dome" eye, like the web Spirit.
private struct DomeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        path.closeSubpath()
        return path
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// ∩-shaped closed happy eye.
private struct HappyArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.55)
        )
        return path
    }
}

/// ∪-shaped sleepy eye.
private struct SleepArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.55)
        )
        return path
    }
}

#Preview {
    NavigationStack { FaceRecordView() }
}

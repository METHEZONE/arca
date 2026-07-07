import SwiftUI

/// The whole Watch app is one friendly face. Idle: round eyes, occasional
/// blink. Recording: eyes curve into happy arcs, a smile appears, the face
/// gently breathes and the label switches to "Listening".
struct FaceRecordView: View {
    @State private var recorder = WatchRecorder()
    @State private var blinkAmount: CGFloat = 1.0
    @State private var breathing = false

    /// Snapshot/preview hook: forces the listening face without recording.
    private let forceListening = ProcessInfo.processInfo.environment["ARCA_PREVIEW_LISTENING"] == "1"

    private var isListening: Bool { recorder.isRecording || forceListening }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 16) {
                FaceView(happy: isListening, blinkAmount: blinkAmount)
                    .frame(width: 110, height: 76)
                    .scaleEffect(breathing && isListening ? 1.07 : 1.0)

                VStack(spacing: 2) {
                    Text(isListening ? "Listening…" : "Tap to record")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(isListening ? .green : .secondary)
                        .opacity(breathing && isListening ? 0.55 : 1.0)

                    if isListening, let startedAt = recorder.startedAt {
                        Text(startedAt, style: .timer)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                if let error = recorder.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await recorder.toggle() }
        }
        .animation(.spring(duration: 0.45, bounce: 0.35), value: isListening)
        .task { await blinkLoop() }
        .onChange(of: isListening) { _, listening in
            if listening {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    breathing = false
                }
            }
        }
    }

    private var background: some View {
        RadialGradient(
            colors: isListening
                ? [Color(red: 0.05, green: 0.22, blue: 0.14), .black]
                : [Color(red: 0.07, green: 0.10, blue: 0.20), .black],
            center: .center, startRadius: 10, endRadius: 140
        )
        .ignoresSafeArea()
    }

    /// Random blinks while idle; happy eyes don't blink.
    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.2...4.2)))
            guard !isListening else { continue }
            withAnimation(.easeIn(duration: 0.08)) { blinkAmount = 0.08 }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeOut(duration: 0.12)) { blinkAmount = 1.0 }
        }
    }
}

// MARK: - Face

private struct FaceView: View {
    let happy: Bool
    let blinkAmount: CGFloat

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 30) {
                Eye(happy: happy, blinkAmount: blinkAmount)
                Eye(happy: happy, blinkAmount: blinkAmount)
            }
            Mouth(happy: happy)
                .frame(width: happy ? 44 : 18, height: happy ? 18 : 5)
        }
    }
}

private struct Eye: View {
    let happy: Bool
    let blinkAmount: CGFloat

    var body: some View {
        ZStack {
            // Idle: round open eye.
            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .scaleEffect(y: blinkAmount, anchor: .center)
                .opacity(happy ? 0 : 1)
                .scaleEffect(happy ? 0.5 : 1)

            // Listening: happy upward arc (^ ^).
            HappyArc()
                .stroke(.white, style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                .frame(width: 24, height: 13)
                .opacity(happy ? 1 : 0)
                .scaleEffect(happy ? 1 : 0.5)
        }
        .frame(width: 26, height: 24)
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

private struct Mouth: View {
    let happy: Bool

    var body: some View {
        ZStack {
            // Idle: small calm line.
            Capsule()
                .fill(.white.opacity(0.85))
                .opacity(happy ? 0 : 1)

            // Listening: wide open smile.
            SmileArc()
                .stroke(.white, style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                .opacity(happy ? 1 : 0)
        }
    }
}

/// ∪-shaped smile.
private struct SmileArc: Shape {
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
    FaceRecordView()
}

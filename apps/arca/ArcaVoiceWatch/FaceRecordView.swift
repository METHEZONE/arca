import SwiftUI

/// The whole Watch app is one living companion. Idle: the orange spirit
/// floats, blinks, glances around, occasionally hops or dozes. Recording:
/// a green ring pulses at the screen edge (the unmistakable "ARCA is
/// listening" boundary), the eyes curve happy, and a timer runs.
struct FaceRecordView: View {
    @State private var recorder = WatchRecorder()
    @State private var transfers = WatchTransferStatus.shared

    // Life-loop state
    @State private var blinkAmount: CGFloat = 1.0
    @State private var eyeOffset: CGSize = .zero
    @State private var hop: CGFloat = 0
    @State private var dozing = false
    @State private var breathing = false
    @State private var ringPulse = false

    /// Snapshot/preview hook: forces the listening face without recording.
    private let forceListening = ProcessInfo.processInfo.environment["ARCA_PREVIEW_LISTENING"] == "1"

    private var isListening: Bool { recorder.isRecording || forceListening }

    var body: some View {
        ZStack {
            background

            // The listening boundary — nothing subtle about it: when this
            // ring is on, ARCA is recording; when it's gone, it isn't.
            RoundedRectangle(cornerRadius: 38)
                .strokeBorder(
                    Color.green.opacity(isListening ? (ringPulse ? 0.35 : 0.95) : 0),
                    lineWidth: 5)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                           value: ringPulse)

            VStack(spacing: 14) {
                SpiritBody(
                    happy: isListening,
                    dozing: dozing && !isListening,
                    blinkAmount: blinkAmount,
                    eyeOffset: eyeOffset
                )
                .frame(width: 108, height: 108)
                .scaleEffect(breathing && isListening ? 1.06 : 1.0)
                .offset(y: hop)

                VStack(spacing: 2) {
                    Text(isListening ? "Listening…" : dozing ? "zzz" : "Tap to record")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(isListening ? .green : .secondary)
                        .opacity(breathing && isListening ? 0.55 : 1.0)

                    if isListening, let startedAt = recorder.startedAt {
                        Text(startedAt, style: .timer)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.8))
                    }

                    if !isListening {
                        transferStatusLine
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
            dozing = false
            Task { await recorder.toggle() }
        }
        .animation(.spring(duration: 0.45, bounce: 0.35), value: isListening)
        .task { await lifeLoop() }
        .onChange(of: isListening) { _, listening in
            ringPulse = listening
            if listening {
                dozing = false
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

    /// Where the last recording is on its journey to the iPhone — the wrist
    /// shouldn't have to wonder whether a send actually happened.
    @ViewBuilder private var transferStatusLine: some View {
        if transfers.sending > 0 {
            Label("Sending to iPhone…", systemImage: "iphone.and.arrow.forward.outward")
                .font(.caption2)
                .foregroundStyle(.orange)
                .transition(.opacity)
        } else if transfers.awaitingSummary {
            Label("On your iPhone — summary soon", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        } else if transfers.sendFailed {
            Label("Send failed — try again near your iPhone", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .transition(.opacity)
        }
    }

    private var background: some View {
        RadialGradient(
            colors: isListening
                ? [Color(red: 0.04, green: 0.18, blue: 0.11), .black]
                : [Color(red: 0.13, green: 0.06, blue: 0.02), .black],
            center: .center, startRadius: 10, endRadius: 150
        )
        .ignoresSafeArea()
    }

    /// Random micro-actions keep the companion alive while idle.
    /// Happy (listening) eyes don't blink and the spirit doesn't wander.
    private func lifeLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.4...5.0)))
            guard !isListening else { continue }

            switch Int.random(in: 0..<10) {
            case 0...3:     // blink
                await blink()
            case 4:         // double blink
                await blink()
                try? await Task.sleep(for: .milliseconds(160))
                await blink()
            case 5, 6:      // glance to a side, hold, back
                dozing = false
                let dx = CGFloat([-7, 7].randomElement()!)
                withAnimation(.easeOut(duration: 0.3)) {
                    eyeOffset = CGSize(width: dx, height: CGFloat.random(in: -3...2))
                }
                try? await Task.sleep(for: .seconds(Double.random(in: 0.7...1.4)))
                withAnimation(.easeInOut(duration: 0.35)) { eyeOffset = .zero }
            case 7:         // happy hop
                dozing = false
                withAnimation(.interpolatingSpring(stiffness: 300, damping: 12)) { hop = -9 }
                try? await Task.sleep(for: .milliseconds(170))
                withAnimation(.interpolatingSpring(stiffness: 260, damping: 14)) { hop = 0 }
            case 8:         // doze off for a while
                withAnimation(.easeInOut(duration: 0.8)) { dozing = true }
                try? await Task.sleep(for: .seconds(Double.random(in: 4...7)))
                withAnimation(.easeOut(duration: 0.4)) { dozing = false }
            default:        // small settle wiggle
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
    let blinkAmount: CGFloat
    let eyeOffset: CGSize

    var body: some View {
        ZStack {
            // Side fins
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

            // Body
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

            // Top spike
            Triangle()
                .fill(Color(red: 0.89, green: 0.2, blue: 0.1))
                .frame(width: 15, height: 13)
                .rotationEffect(.degrees(18))
                .offset(x: 20, y: -44)

            // Face
            FaceEyes(happy: happy, dozing: dozing, blinkAmount: blinkAmount)
                .offset(eyeOffset)
        }
    }
}

private struct FaceEyes: View {
    let happy: Bool
    let dozing: Bool
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
            // Idle: cream dome eye (blinks).
            DomeShape()
                .fill(cream)
                .frame(width: 17, height: 15)
                .scaleEffect(y: blinkAmount, anchor: .bottom)
                .opacity(happy || dozing ? 0 : 1)

            // Listening: happy upward arc.
            HappyArc()
                .stroke(cream, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .frame(width: 18, height: 10)
                .opacity(happy ? 1 : 0)

            // Dozing: sleepy downward crescent.
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
    FaceRecordView()
}

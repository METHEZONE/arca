#if os(macOS)
import SwiftUI
import ArcaVoiceKit

/// ARCA's face in the notch. When idle the black shape matches the physical
/// notch exactly (nothing extra is covered); active surfaces extend it
/// downward and all content lives in that extension ("the chin").
struct NotchView: View {
    let agent: NotchAgent
    let coordinator: RecordingCoordinator
    let geometry: NotchWindowController.NotchGeometry

    @State private var blinkAmount: CGFloat = 1.0
    @State private var breathing = false
    /// "cozy" = eyes peek below the notch; "clean" = invisible until needed.
    @AppStorage("notchStyle") private var notchStyle = "cozy"

    private enum Surface: Equatable {
        case idle, menu, recording, stopping
        case meetingPrompt(String)
        case screenshotPrompt(URL)
        case readingCapture
        case planReady(String)
        case notice(String)
        case celebrate(String)
        case chat
        case dropTarget
        case dashboard
    }

    private var surface: Surface {
        switch coordinator.phase {
        case .recording: return .recording
        case .stopping: return .stopping
        case .idle:
            switch agent.mode {
            case .idle: return .idle
            case .menu: return .menu
            case .meetingPrompt(let label): return .meetingPrompt(label)
            case .screenshotPrompt(let url): return .screenshotPrompt(url)
            case .readingCapture: return .readingCapture
            case .planReady(let offer): return .planReady(offer)
            case .notice(let text): return .notice(text)
            case .celebrate(let title): return .celebrate(title)
            case .chat: return .chat
            case .dropTarget: return .dropTarget
            case .dashboard: return .dashboard
            }
        }
    }

    /// Band surfaces live INSIDE the menu-bar strip (the notch's own height,
    /// flanking it) — they never cover the screen below. Everything else
    /// drops down as a black extension.
    private var isBand: Bool {
        guard geometry.hasNotch else { return false }
        switch surface {
        case .idle, .recording, .stopping: return true
        default: return false
        }
    }

    /// Width of each flank beside the notch for band surfaces.
    private var bandSideWidth: CGFloat {
        switch surface {
        case .recording, .stopping: return 150
        default: return 44
        }
    }

    private var shapeSize: CGSize {
        let notchW = geometry.notchWidth
        let notchH = geometry.hasNotch ? geometry.notchHeight : 0
        if isBand {
            return CGSize(width: notchW + bandSideWidth * 2, height: notchH)
        }
        switch surface {
        case .idle:
            // External displays: a small pill below the menu bar.
            return CGSize(width: 150, height: 30)
        case .menu:
            return CGSize(width: notchW + 250, height: notchH + 52)
        case .recording, .stopping:
            return CGSize(width: notchW + 290, height: notchH + 52)
        case .meetingPrompt:
            return CGSize(width: notchW + 430, height: notchH + 60)
        case .screenshotPrompt:
            return CGSize(width: notchW + 430, height: notchH + 60)
        case .readingCapture, .notice:
            return CGSize(width: notchW + 330, height: notchH + 54)
        case .celebrate:
            return CGSize(width: notchW + 330, height: notchH + 54)
        case .planReady:
            return CGSize(width: notchW + 430, height: notchH + 60)
        case .dropTarget:
            return CGSize(width: notchW + 220, height: notchH + 150)
        case .chat:
            return CGSize(width: 640, height: 520)
        case .dashboard:
            return CGSize(width: notchW + 740, height: 500)
        }
    }

    /// The black shape's own frame: parked exactly behind the physical notch
    /// while banded (zero extra pixels covered), the full surface otherwise.
    /// Keeping the shape in the tree at all times is what lets it GROW out of
    /// the notch — the mouth-opening spring — instead of just appearing.
    private var mouthSize: CGSize {
        if isBand {
            return CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
        }
        return shapeSize
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topFlat: geometry.hasNotch)
                    .fill(.black)
                    .frame(width: mouthSize.width, height: mouthSize.height)
                if isBand {
                    // Menu-bar band: no black extension — ARCA and its status
                    // sit beside the physical notch like they belong there.
                    bandContent
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                } else {
                    content
                        .padding(.top, geometry.hasNotch ? geometry.notchHeight : 0)
                        .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
                        // Let the mouth lead: content fades in a beat after the
                        // shape springs open, and vanishes first on close.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.1)),
                            removal: .opacity.animation(.easeIn(duration: 0.08))))
                }
            }
            .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
            .animation(.spring(duration: 0.38, bounce: 0.26), value: surface)

            Spacer(minLength: 0)
        }
        // Fill the fixed hosting frame exactly so the SwiftUI root size never
        // changes — only the inner shape animates. Prevents the NSHostingView
        // from churning the window's Auto Layout (which crashed AppKit).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await blinkLoop() }
        .onChange(of: surface == .recording) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { breathing = false }
            }
        }
    }

    // MARK: - Menu-bar band (idle / recording) — vibe-island style

    private var bandMood: ArcaFace.Mood {
        switch surface {
        case .recording: return .listening
        case .stopping: return .thinking
        default:
            switch idleState {
            case .zone: return .zone
            case .working: return .working
            case .plain: return .idle
            }
        }
    }

    private var bandContent: some View {
        HStack(spacing: 0) {
            // Left flank: ARCA sits right up against the notch's left edge.
            HStack {
                Spacer(minLength: 0)
                if !(notchStyle == "clean" && surface == .idle) {
                    ArcaFace(mood: bandMood,
                             size: max(18, geometry.notchHeight * 0.72),
                             look: agent.pointerLook,
                             halo: false)
                        .contentShape(Circle())
                        .onTapGesture { agent.hoverOpen() }
                        .padding(.trailing, 6)
                }
            }
            .frame(width: bandSideWidth)

            // The physical notch — dead pixels, draw nothing.
            Color.clear
                .frame(width: geometry.notchWidth)
                .contentShape(Rectangle())
                .onTapGesture { agent.hoverOpen() }

            // Right flank: live details in a legible pill.
            HStack {
                rightBandDetails
                Spacer(minLength: 0)
            }
            .frame(width: bandSideWidth)
        }
        .frame(height: geometry.notchHeight)
    }

    @ViewBuilder
    private var rightBandDetails: some View {
        switch surface {
        case .recording:
            HStack(spacing: 6) {
                Circle().fill(.red)
                    .frame(width: 6, height: 6)
                    .opacity(breathing ? 0.45 : 1)
                if let startedAt = coordinator.startedAt {
                    Text(startedAt, style: .timer)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                }
                Button {
                    agent.stopRecording()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(.red.opacity(0.85), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.85), in: Capsule())
            .padding(.leading, 6)
        case .stopping:
            Text("Wrapping up…")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.black.opacity(0.85), in: Capsule())
                .padding(.leading, 6)
        default:
            switch idleState {
            case .working:
                Circle().fill(ArcaSkins.current.hi)
                    .frame(width: 6, height: 6)
                    .opacity(breathing ? 0.4 : 1)
                    .padding(.leading, 8)
            case .zone:
                Image(systemName: "moon.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(ArcaFace.zoneViolet)
                    .padding(.leading, 8)
            case .plain:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch surface {
        case .idle:
            // External-display pill only (band handles notched displays).
            idleEyes
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .onTapGesture { agent.hoverOpen() }

        case .menu:
            HStack(spacing: 10) {
                miniFace(happy: false)
                Spacer()
                chipButton("Record", icon: "mic.fill", prominent: true) {
                    agent.startRecordingFromMenu()
                }
                chipButton("Open app", icon: "rectangle.on.rectangle") {
                    agent.openApp()
                }
            }
            .padding(.horizontal, 16)

        case .recording, .stopping:
            HStack(spacing: 12) {
                miniFace(happy: true)
                    .scaleEffect(breathing ? 1.1 : 1.0)
                if surface == .stopping {
                    Text("Wrapping up…")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Listening")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(.green)
                        .opacity(breathing ? 0.6 : 1.0)
                    if let startedAt = coordinator.startedAt {
                        Text(startedAt, style: .timer)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer()
                if surface == .recording {
                    Button {
                        agent.stopRecording()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.red.opacity(0.85), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

        case .meetingPrompt(let label):
            promptRow(
                icon: "waveform.badge.mic", tint: .blue,
                title: "Looks like \(label) just started",
                subtitle: "Start transcribing? Both sides are captured separately.",
                acceptTitle: "Transcribe", onAccept: { agent.acceptMeeting() },
                onDismiss: { agent.dismissMeeting() })

        case .screenshotPrompt(let url):
            promptRow(
                icon: "camera.viewfinder", tint: .orange,
                title: "New screenshot",
                subtitle: "Want me to read it and draft an action plan?",
                acceptTitle: "Read it", onAccept: { agent.acceptScreenshot(url) },
                onDismiss: { agent.dismissScreenshot() })

        case .readingCapture:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Reading…")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
            }
            .padding(.horizontal, 18)

        case .planReady(let offer):
            promptRow(
                icon: "sparkles", tint: .green,
                title: offer,
                subtitle: "Action plan saved.",
                acceptTitle: "Open", onAccept: { agent.openPlan() },
                onDismiss: { agent.dismissScreenshot() })

        case .celebrate(let title):
            HStack(spacing: 10) {
                ArcaFace(mood: .happy, size: 26, halo: false)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ArcaSkins.current.hi)
                    .symbolEffect(.bounce, options: .repeat(2))
                Text("Done — \(title)")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)

        case .notice(let text):
            HStack(spacing: 10) {
                miniFace(happy: false)
                Text(text)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 16)

        case .dropTarget:
            VStack(spacing: 8) {
                miniFace(happy: true)
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.plus")
                                .font(.title2)
                            Text("Drop the shot here")
                                .font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            .padding(.top, 6)

        case .chat:
            if let chat = agent.chat {
                ChatPanel(chat: chat, onClose: { agent.closeChat() })
                    .padding(.top, geometry.hasNotch ? 2 : 6)
            }

        case .dashboard:
            DashboardView(agent: agent)
                .padding(.top, geometry.hasNotch ? geometry.notchHeight + 4 : 8)
        }
    }

    // MARK: - Pieces

    /// What ARCA is up to right now — the idle eyes wear it.
    private enum IdleState { case plain, working, zone }

    private var idleState: IdleState {
        if AppServices.shared.zone.isActive { return .zone }
        if TaskEngine.shared.runningCount > 0 { return .working }
        return .plain
    }

    private var eyeFill: LinearGradient {
        LinearGradient(colors: [ArcaFace.eyeTop, ArcaFace.eyeBottom],
                       startPoint: .top, endPoint: .bottom)
    }

    private var idleEyes: some View {
        let state = idleState
        let skin = ArcaSkins.current
        let glow: Color = switch state {
        case .plain: skin.mid
        case .working: skin.hi
        case .zone: ArcaFace.zoneViolet
        }
        return HStack(spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                switch state {
                case .zone:
                    // Closed violet crescents — guarding, do not disturb.
                    MiniHappyArc()
                        .stroke(ArcaFace.zoneViolet,
                                style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                        .frame(width: 11, height: 5)
                        .scaleEffect(y: -1)
                        .shadow(color: ArcaFace.zoneViolet.opacity(0.9), radius: 3)
                case .working:
                    // Determined squint in the skin's color — hard at work.
                    DomeEye()
                        .fill(skin.hi)
                        .frame(width: 10, height: 6)
                        .shadow(color: skin.mid.opacity(0.9),
                                radius: breathing ? 3.5 : 1.5)
                case .plain:
                    DomeEye()
                        .fill(eyeFill)
                        .frame(width: 9, height: 13)
                        .scaleEffect(y: blinkAmount, anchor: .bottom)
                        .shadow(color: glow.opacity(0.8), radius: 2.5)
                }
            }
        }
        // Eyes drift after the cursor — Dasai-Mochi lazy, never snappy.
        .offset(x: agent.pointerLook.x * 3,
                y: -3 + agent.pointerLook.y * 1.8)
        .animation(.easeOut(duration: 0.5), value: agent.pointerLook)
        .frame(height: geometry.hasNotch ? 22 : 30)
        .task(id: state == .working) {
            guard state == .working else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    private func miniFace(happy: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { _ in
                if happy {
                    MiniHappyArc()
                        .stroke(eyeFill, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 10, height: 6)
                        .shadow(color: ArcaSkins.current.mid.opacity(0.8), radius: 2)
                } else {
                    DomeEye()
                        .fill(eyeFill)
                        .frame(width: 8, height: 11)
                        .scaleEffect(y: blinkAmount, anchor: .bottom)
                        .shadow(color: ArcaSkins.current.mid.opacity(0.7), radius: 2)
                }
            }
        }
    }

    private func promptRow(icon: String, tint: Color, title: String, subtitle: String,
                           acceptTitle: String, onAccept: @escaping () -> Void,
                           onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            chipButton("Later", icon: nil) { onDismiss() }
            chipButton(acceptTitle, icon: nil, prominent: true) { onAccept() }
        }
        .padding(.horizontal, 16)
    }

    private func chipButton(_ title: String, icon: String?, prominent: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(prominent ? AnyShapeStyle(ArcaTheme.idle) : AnyShapeStyle(.white.opacity(0.14)),
                        in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.5...4.5)))
            guard surface == .idle || surface == .menu else { continue }
            withAnimation(.easeIn(duration: 0.08)) { blinkAmount = 0.1 }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeOut(duration: 0.12)) { blinkAmount = 1.0 }
        }
    }
}

/// The notch extension: flat top (merges with the physical notch), rounded
/// bottom corners. On external displays it becomes a fully rounded pill.
private struct NotchShape: Shape {
    let topFlat: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = topFlat ? 14 : rect.height / 2
        if topFlat {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        } else {
            return Path(roundedRect: rect, cornerRadius: radius)
        }
    }
}

private struct MiniHappyArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.4))
        return path
    }
}
#endif

import SwiftUI

/// ARCA — the round spirit from the brand site (app/arca/page.tsx Spirit):
/// a glossy gradient orb with side fins, a tilted horn, and cream dome eyes.
/// Parametric size, skinnable, animates by mood, eyes can track a point.
struct ArcaFace: View {
    enum Mood: Equatable {
        case idle        // dome eyes + blink + gentle bob
        case listening   // happy arcs + sonar ring
        case thinking    // narrowed eyes + slow orbit spark
        case working     // determined squint + fast orbit + effort wiggle
        case happy       // arcs + bounce
        case zone        // closed crescent eyes + violet aura — do not disturb
    }

    var mood: Mood = .idle
    var size: CGFloat = 180
    /// Where the eyes look, normalized -1…1 (0 = straight ahead).
    var look: CGPoint = .zero
    /// Draw the ambient halo behind the body (off for tight surfaces).
    var halo: Bool = true
    /// Override the skin (nil = the user's selected skin).
    var skinOverride: ArcaSkin?
    /// Idle micro-behaviors (glances, hops, dozing). On by default — ARCA
    /// should feel alive everywhere; turn off for static previews.
    var alive: Bool = true

    /// One-off idle behaviors so ARCA never just sits there.
    private enum MicroAct: Equatable {
        case none
        case glance(CGFloat)   // -1 left … 1 right
        case happy
        case doze
    }

    @State private var blink: CGFloat = 1.0
    @State private var bob = false
    @State private var orbit = false
    @State private var pulse = false
    @State private var skinTick = 0
    @State private var act: MicroAct = .none
    @State private var hop: CGFloat = 0

    /// Reduced motion means fewer/gentler animations, not zero — the
    /// continuous bob/orbit/pulse loops and idle fidgeting (hops, floats)
    /// are movement, so they stop; the mood-driven eye shape still changes.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Site tokens
    static let eyeTop = Color(red: 1.0, green: 0.965, blue: 0.925)    // #fff6ec
    static let eyeBottom = Color(red: 1.0, green: 0.890, blue: 0.788) // #ffe3c9
    static let zoneViolet = Color(red: 0.725, green: 0.608, blue: 1.0) // #b99bff
    /// Brand accent (kept for existing call sites).
    static let ember = Color(red: 1.0, green: 0.478, blue: 0.102)
    static let emberSoft = Color(red: 1.0, green: 0.604, blue: 0.235)
    static let emberCore = Color(red: 1.0, green: 0.906, blue: 0.8)
    /// Warm charcoal surface tokens (DESIGN.md) — used by dark cards/sheets.
    static let bodyTop = Color(red: 0.165, green: 0.094, blue: 0.071)
    static let bodyBottom = Color(red: 0.082, green: 0.047, blue: 0.027)
    static let stroke = Color(red: 0.478, green: 0.290, blue: 0.165)

    private var skin: ArcaSkin { skinOverride ?? ArcaSkins.current }

    private var auraColor: Color { mood == .zone ? Self.zoneViolet : skin.mid }

    var body: some View {
        // Site viewBox is 100×100; everything below is in those units × s.
        let s = size / 100
        let _ = skinTick // re-render on skin change

        ZStack {
            if halo {
                Circle()
                    .fill(auraColor)
                    .frame(width: 78 * s, height: 78 * s)
                    .blur(radius: 14 * s)
                    .opacity(mood == .zone ? 0.5 : mood == .listening ? 0.45 : 0.3)
            }

            if mood == .listening || mood == .zone {
                Circle()
                    .stroke(auraColor.opacity(0.55), lineWidth: 1.4 * s)
                    .frame(width: 84 * s, height: 84 * s)
                    .scaleEffect(pulse ? 1.14 : 0.98)
                    .opacity(pulse ? 0.12 : 0.55)
            }

            // fins (bob slightly out of phase with the body)
            finShape(s: s)
                .offset(x: -38 * s, y: 12 * s + (bob ? -1.6 * s : 1.6 * s))
            finShape(s: s)
                .offset(x: 38 * s, y: 12 * s + (bob ? 1.6 * s : -1.6 * s))

            // body group (horn + orb + sheen + eyes) bobs together
            ZStack {
                HornShape()
                    .fill(skin.lo)
                    .frame(width: 14 * s, height: 18 * s)
                    .offset(x: 21 * s, y: -39 * s)

                Circle()
                    .fill(RadialGradient(
                        stops: [
                            .init(color: skin.hi, location: 0),
                            .init(color: skin.mid, location: 0.55),
                            .init(color: skin.lo, location: 1),
                        ],
                        center: UnitPoint(x: 0.36, y: 0.30),
                        startRadius: 0,
                        endRadius: 54 * s))
                    .frame(width: 68 * s, height: 68 * s)
                    .shadow(color: auraColor.opacity(0.55), radius: 8 * s)

                Ellipse()
                    .fill(.white.opacity(0.28))
                    .frame(width: 24 * s, height: 16 * s)
                    .offset(x: -12 * s, y: -16 * s)

                eyes(s: s)
                    .offset(x: effectiveLook.x * max(2.4, 3.2 * s),
                            y: effectiveLook.y * max(1.6, 2.4 * s))
                    .animation(.easeOut(duration: 0.5), value: look)
                    .animation(.easeInOut(duration: 0.45), value: act)

                if mood == .thinking || mood == .working {
                    Circle()
                        .fill(skin.hi)
                        .frame(width: max(3, 4.5 * s), height: max(3, 4.5 * s))
                        .offset(y: -44 * s)
                        .rotationEffect(.degrees(orbit ? 360 : 0))
                        .shadow(color: skin.hi.opacity(0.9), radius: 2 * s)
                }
            }
            // Motion floors: at tiny sizes the scaled travel would be
            // sub-pixel — clamp so the float always reads as "alive".
            .offset(y: (bob ? -1 : 1) * max(1.6, 2 * s) + hop)
            .rotationEffect(mood == .working ? .degrees(bob ? -2.2 : 2.2) : .degrees(0))

            // ZONE: ARCA holds the shield, on guard duty.
            if mood == .zone {
                Image(systemName: "shield.fill")
                    .font(.system(size: max(9, 26 * s), weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [Self.zoneViolet,
                                                Self.zoneViolet.opacity(0.65)],
                                       startPoint: .top, endPoint: .bottom))
                    .shadow(color: Self.zoneViolet.opacity(0.8), radius: max(2, 4 * s))
                    .rotationEffect(.degrees(bob ? -7 : 3))
                    .offset(x: -26 * s, y: 16 * s + (bob ? -1 : 1) * max(1.2, 1.5 * s))
            }
        }
        .onAppear { syncMotion() }
        .onChange(of: mood) { _, _ in syncMotion() }
        .task { await blinkLoop() }
        .task { await lifeLoop() }
        .onReceive(NotificationCenter.default.publisher(for: .arcaSkinChanged)) { _ in
            skinTick += 1
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: mood)
    }

    /// Long-lived moods (idle, zone) must not run continuous animation: a
    /// repeatForever loop re-renders the whole face at display refresh rate
    /// for hours and was measured burning ~58% CPU at idle. They stay static
    /// and get their life from `lifeLoop`'s periodic micro-acts instead;
    /// only the short-lived active moods run continuous loops.
    private func syncMotion() {
        guard !reduceMotion else {
            // Reduced motion: no continuous bob/orbit/pulse. The mood still
            // reads through the eye shape and aura color/opacity alone.
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { bob = false; orbit = false; pulse = false }
            return
        }

        switch mood {
        case .idle, .zone:
            withAnimation(.easeInOut(duration: 0.6)) { bob = false }
        case .listening, .thinking, .working, .happy:
            withAnimation(.easeInOut(duration: mood == .working ? 0.5 : 2.6)
                .repeatForever(autoreverses: true)) { bob = true }
        }

        if mood == .thinking || mood == .working {
            var reset = Transaction(); reset.disablesAnimations = true
            withTransaction(reset) { orbit = false }
            withAnimation(.linear(duration: mood == .working ? 1.1 : 2.6)
                .repeatForever(autoreverses: false)) { orbit = true }
        } else {
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { orbit = false }
        }

        if mood == .listening {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { pulse = false }
        }
    }

    /// Where the eyes actually point — a glance briefly overrides the cursor.
    private var effectiveLook: CGPoint {
        if case .glance(let direction) = act {
            return CGPoint(x: direction, y: look.y * 0.3)
        }
        return look
    }

    /// How the eyes render right now (moods + idle micro-acts).
    private enum EyeStyle { case dome, arcs, squint, zoneCrescent, dozeCrescent }

    private var eyeStyle: EyeStyle {
        if mood == .idle {
            switch act {
            case .happy: return .arcs
            case .doze: return .dozeCrescent
            default: return .dome
            }
        }
        switch mood {
        case .listening, .happy: return .arcs
        case .zone: return .zoneCrescent
        case .thinking, .working: return .squint
        case .idle: return .dome
        }
    }

    // MARK: - Pieces (site geometry, /100 units)

    private func finShape(s: CGFloat) -> some View {
        Ellipse()
            .fill(skin.fin)
            .frame(width: 18 * s, height: 12 * s)
    }

    @ViewBuilder
    private func eyes(s: CGFloat) -> some View {
        let eyeW = 18 * s
        let gap = 8 * s
        let cream = LinearGradient(colors: [Self.eyeTop, Self.eyeBottom],
                                   startPoint: .top, endPoint: .bottom)
        HStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { _ in
                switch eyeStyle {
                case .arcs:
                    HappyArcEye()
                        .stroke(cream,
                                style: StrokeStyle(lineWidth: 3.6 * s, lineCap: .round))
                        .frame(width: eyeW * 0.82, height: 8 * s)
                case .zoneCrescent:
                    HappyArcEye()
                        .stroke(Self.zoneViolet.opacity(0.95),
                                style: StrokeStyle(lineWidth: 3.4 * s, lineCap: .round))
                        .frame(width: eyeW * 0.82, height: 6.5 * s)
                        .scaleEffect(y: -1) // closed crescents — on watch duty
                case .dozeCrescent:
                    HappyArcEye()
                        .stroke(cream,
                                style: StrokeStyle(lineWidth: 3.4 * s, lineCap: .round))
                        .frame(width: eyeW * 0.82, height: 6 * s)
                        .scaleEffect(y: -1) // dozed off for a second
                case .squint:
                    DomeEye()
                        .fill(cream)
                        .frame(width: eyeW, height: 6.5 * s) // determined squint
                case .dome:
                    DomeEye()
                        .fill(cream)
                        .frame(width: eyeW, height: 14 * s)
                        .scaleEffect(y: blink, anchor: .bottom)
                }
            }
        }
        .offset(y: -3 * s)
    }

    /// The soul: every few seconds ARCA does one small thing — glances off,
    /// double-blinks, hops, grins, or dozes. Idle only; never busy, never loud.
    private func lifeLoop() async {
        // Hops, floats, and glances are all movement — skip the whole loop
        // under reduced motion rather than thin it out piecemeal.
        guard alive, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 5...13)))
            // ZONE breathes once in a while — a single aura pulse, then rest.
            // (Continuous pulse would pin the render loop for hours.)
            if mood == .zone {
                withAnimation(.easeInOut(duration: 1.4)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(1500))
                withAnimation(.easeInOut(duration: 1.4)) { pulse = false }
                continue
            }
            guard mood == .idle, act == .none else { continue }
            switch Int.random(in: 0..<7) {
            case 0, 1: // glance off to one side, then back
                act = .glance(Bool.random() ? 1 : -1)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 900...1600)))
                act = .none
            case 2: // double blink
                for _ in 0..<2 {
                    withAnimation(.easeIn(duration: 0.06)) { blink = 0.08 }
                    try? await Task.sleep(for: .milliseconds(90))
                    withAnimation(.easeOut(duration: 0.1)) { blink = 1.0 }
                    try? await Task.sleep(for: .milliseconds(120))
                }
            case 3: // a happy little hop
                act = .happy
                withAnimation(.spring(duration: 0.22, bounce: 0.6)) {
                    hop = -max(3, 5 * size / 100)
                }
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.spring(duration: 0.4, bounce: 0.55)) { hop = 0 }
                try? await Task.sleep(for: .milliseconds(700))
                act = .none
            case 4: // doze off for a moment
                act = .doze
                try? await Task.sleep(for: .seconds(Double.random(in: 1.8...3.0)))
                act = .none
            case 5: // a slow float — a few gentle bobs, then settle back down
                withAnimation(.easeInOut(duration: 1.3).repeatCount(3, autoreverses: true)) {
                    bob = true
                }
                try? await Task.sleep(for: .seconds(3.9))
                withAnimation(.easeInOut(duration: 0.8)) { bob = false }
            default: // tiny hop only
                withAnimation(.spring(duration: 0.2, bounce: 0.55)) {
                    hop = -max(2, 3 * size / 100)
                }
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.spring(duration: 0.35, bounce: 0.5)) { hop = 0 }
            }
        }
    }

    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.4...5.0)))
            guard mood == .idle else { continue }
            withAnimation(.easeIn(duration: 0.07)) { blink = 0.08 }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeOut(duration: 0.12)) { blink = 1.0 }
        }
    }
}

/// Back-compat for earlier surfaces.
typealias SpiritFace = ArcaFace

/// The site's dome eye: rounded shoulders, flat bottom
/// ("M28 58 Q28 44 37 44 Q46 44 46 58 Z" scaled).
struct DomeEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The site's happy arc: "M30 54 Q37 46 44 54".
struct HappyArcEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.2))
        return path
    }
}

/// The tilted horn: site path M64,16 L78,8 L74,26 (normalized).
struct HornShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.44))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.71, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview("moods × skins") {
    VStack(spacing: 24) {
        HStack(spacing: 28) {
            ArcaFace(mood: .idle, size: 110)
            ArcaFace(mood: .listening, size: 110)
            ArcaFace(mood: .working, size: 110)
        }
        HStack(spacing: 28) {
            ArcaFace(mood: .zone, size: 110)
            ArcaFace(mood: .happy, size: 110, skinOverride: ArcaSkins.all[1])
            ArcaFace(mood: .idle, size: 110, skinOverride: ArcaSkins.all[4])
        }
    }
    .padding(50)
    .background(Color(red: 0.03, green: 0.05, blue: 0.09))
}

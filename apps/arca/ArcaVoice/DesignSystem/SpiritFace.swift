import SwiftUI
import ArcaVoiceKit

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
    /// The eyes follow the pointer over the face and hovering gets a little
    /// smile. Hover-only — never intercepts clicks, so it's safe inside a
    /// Button (the home hero is a tap-to-record button).
    var followsPointer: Bool = false
    /// Full emotional interactivity: `followsPointer` plus a squash-and-bounce
    /// grin on tap. Only for faces that are NOT already buttons.
    var interactive: Bool = false
    /// Hero surfaces only: between glances ARCA also lives a little — snacks,
    /// watches something, types, listens to music, stretches. Props are drawn
    /// in front of the body; the caption is reported through `onActivity`.
    var activities: Bool = false
    var onActivity: ((Activity?) -> Void)? = nil

    /// What ARCA is up to right now, for captions ("과자 먹는 중").
    enum Activity: Equatable {
        case snack, tv, code, music, stretch

        var caption: String {
            switch self {
            case .snack: return L("간식 먹는 중", "Having a snack")
            case .tv: return L("잠깐 TV 보는 중", "Watching a little TV")
            case .code: return L("코드 두드리는 중", "Tapping out some code")
            case .music: return L("음악 듣는 중", "Listening to music")
            case .stretch: return L("스트레칭 중", "Stretching")
            }
        }
    }

    /// One-off idle behaviors so ARCA never just sits there.
    private enum MicroAct: Equatable {
        case none
        case glance(CGFloat)   // -1 left … 1 right
        case happy
        case doze
        case activity(Activity)
    }

    @State private var blink: CGFloat = 1.0
    @State private var bob = false
    @State private var orbit = false
    @State private var pulse = false
    @State private var skinTick = 0
    @State private var act: MicroAct = .none
    @State private var hop: CGFloat = 0
    @State private var tilt: CGFloat = 0
    @State private var squish: CGFloat = 1
    /// Pointer position over the face, normalized — overrides `look`.
    @State private var hoverLook: CGPoint?
    /// Prop animation phase (0…1 looping) while an activity plays.
    @State private var propPhase: CGFloat = 0
    @State private var propBeat = false

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
            .scaleEffect(x: 2 - squish, y: squish, anchor: .bottom)
            .offset(y: (bob ? -1 : 1) * max(1.6, 2 * s) + hop)
            .rotationEffect(mood == .working ? .degrees(bob ? -2.2 : 2.2) : .degrees(tilt))

            if case .activity(let activity) = act {
                activityProps(activity, s: s)
            }

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
        .contentShape(Circle())
        // Only an interactive face owns the tap. A gesture that merely ignores
        // the tap still swallows it, and the phone's home hero (tap to record)
        // and the Mac record button sit *behind* this view.
        .modifier(TapIfInteractive(enabled: interactive) { happyBurst() })
        .onContinuousHover { phase in
            guard interactive || followsPointer else { return }
            switch phase {
            case .active(let point):
                // First contact: perk up with a quick smile — it noticed you.
                if hoverLook == nil, act == .none, mood == .idle, !reduceMotion {
                    Task { @MainActor in
                        act = .happy
                        try? await Task.sleep(for: .milliseconds(750))
                        if act == .happy { act = .none }
                    }
                }
                let dx = max(-1, min(1, (point.x - size / 2) / (size / 2)))
                let dy = max(-1, min(1, (point.y - size / 2) / (size / 2)))
                // Deadzone so pointer jitter doesn't twitch the eyes.
                if let current = hoverLook,
                   abs(dx - current.x) < 0.05, abs(dy - current.y) < 0.05 { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    hoverLook = CGPoint(x: dx, y: dy)
                }
            case .ended:
                withAnimation(.easeOut(duration: 0.6)) { hoverLook = nil }
            }
        }
    }

    /// Long-lived moods must not run continuous animation: a repeatForever
    /// loop re-renders the whole face at display refresh rate for as long as
    /// the mood holds, and was measured burning ~58% CPU sustained. `.idle`
    /// and `.zone` were fixed for this already; `.listening` and `.happy` are
    /// exactly as unbounded and were still doing it — `.listening` runs for
    /// an entire recording (a real meeting can go an hour-plus) and `.happy`
    /// sits on decision screens (skin picker, onboarding) for as long as the
    /// user takes to read and choose. Measured on 2026-08-13: an idle
    /// `.listening` face alone sustained 60–65% CPU for the whole recording.
    /// They stay static and get their life from `lifeLoop`'s periodic
    /// bursts instead; only the genuinely short, self-resolving moods
    /// (`.thinking`, `.working` — a few seconds to at most a couple of
    /// minutes while something actually completes) run continuous loops.
    private func syncMotion() {
        guard !reduceMotion else {
            // Reduced motion: no continuous bob/orbit/pulse. The mood still
            // reads through the eye shape and aura color/opacity alone.
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { bob = false; orbit = false; pulse = false }
            return
        }

        switch mood {
        case .idle, .zone, .listening, .happy:
            withAnimation(.easeInOut(duration: 0.6)) { bob = false }
        case .thinking, .working:
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

        // `.listening`'s sonar ring now breathes in bursts from `lifeLoop`
        // rather than continuously — reset to off here, same as `.zone`.
        var still = Transaction(); still.disablesAnimations = true
        withTransaction(still) { pulse = false }
    }

    /// Where the eyes actually point — a glance briefly overrides the cursor,
    /// and a pointer hovering the face itself wins over everything.
    private var effectiveLook: CGPoint {
        if let hoverLook { return hoverLook }
        if case .glance(let direction) = act {
            return CGPoint(x: direction, y: look.y * 0.3)
        }
        return look
    }

    /// Tap response: a squash, a bounce, and a grin — ARCA noticed you.
    private func happyBurst() {
        guard act != .happy else { return }
        if reduceMotion {
            // Still acknowledge the tap, just without movement.
            Task { @MainActor in
                act = .happy
                try? await Task.sleep(for: .milliseconds(1200))
                if act == .happy { act = .none }
            }
            return
        }
        Task { @MainActor in
            act = .happy
            withAnimation(.spring(duration: 0.14, bounce: 0.4)) { squish = 0.86 }
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.spring(duration: 0.3, bounce: 0.65)) {
                squish = 1
                hop = -max(4, 8 * size / 100)
            }
            try? await Task.sleep(for: .milliseconds(240))
            withAnimation(.spring(duration: 0.45, bounce: 0.55)) { hop = 0 }
            try? await Task.sleep(for: .milliseconds(1100))
            if act == .happy { act = .none }
        }
    }

    /// How the eyes render right now (moods + idle micro-acts).
    private enum EyeStyle { case dome, arcs, squint, zoneCrescent, dozeCrescent }

    private var eyeStyle: EyeStyle {
        if mood == .idle {
            switch act {
            case .happy: return .arcs
            case .doze: return .dozeCrescent
            case .activity(let activity):
                switch activity {
                case .code, .tv: return .squint       // concentrating
                case .music, .snack: return .arcs     // content
                case .stretch: return .dozeCrescent   // eyes closed, aaah
                }
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
    /// double-blinks, hops, cocks its head, looks around, or dozes. Hero
    /// surfaces fidget noticeably more; small status faces stay calm. Late at
    /// night it gets visibly sleepy. All bursts, never continuous loops.
    private func lifeLoop() async {
        // Hops, floats, and glances are all movement — skip the whole loop
        // under reduced motion rather than thin it out piecemeal.
        guard alive, !reduceMotion else { return }
        let hero = interactive || followsPointer || size >= 100
        while !Task.isCancelled {
            let pause = hero ? Double.random(in: 2.8...6.5) : Double.random(in: 5...13)
            try? await Task.sleep(for: .seconds(pause))
            // ZONE breathes once in a while — a single aura pulse, then rest.
            // (Continuous pulse would pin the render loop for hours.)
            if mood == .zone {
                withAnimation(.easeInOut(duration: 1.4)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(1500))
                withAnimation(.easeInOut(duration: 1.4)) { pulse = false }
                continue
            }
            // LISTENING breathes the same way — a recording runs as long as
            // the meeting does, so this is the loop that was actually
            // measured burning 60%+ CPU as a continuous animation.
            if mood == .listening {
                withAnimation(.easeInOut(duration: 1.1)) { bob = true; pulse = true }
                try? await Task.sleep(for: .milliseconds(1100))
                withAnimation(.easeInOut(duration: 1.1)) { bob = false; pulse = false }
                continue
            }
            guard mood == .idle, act == .none else { continue }

            let hour = Calendar.current.component(.hour, from: Date())
            let sleepy = hour >= 23 || hour < 7
            // Hero surfaces with activities on: about a third of the time ARCA
            // does something with its hands instead of just fidgeting.
            if activities, Int.random(in: 0..<3) == 0 {
                await perform(activity: [Activity.snack, .tv, .code, .music, .stretch].randomElement()!,
                              sleepy: sleepy)
                continue
            }
            // A sleepy ARCA nods off far more often — it's 2am, let it yawn.
            let roll = (sleepy && Int.random(in: 0..<3) == 0) ? 4 : Int.random(in: 0..<9)
            switch roll {
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
            case 4: // doze off — longer and droopier late at night
                act = .doze
                withAnimation(.easeInOut(duration: 1.2)) { tilt = sleepy ? 5 : 2 }
                try? await Task.sleep(for: .seconds(Double.random(in: sleepy ? 3.0...5.5 : 1.8...3.0)))
                withAnimation(.spring(duration: 0.5, bounce: 0.4)) { tilt = 0 }
                act = .none
            case 5: // a slow float — a few gentle bobs, then settle back down
                withAnimation(.easeInOut(duration: 1.3).repeatCount(3, autoreverses: true)) {
                    bob = true
                }
                try? await Task.sleep(for: .seconds(3.9))
                withAnimation(.easeInOut(duration: 0.8)) { bob = false }
            case 6: // curious — cocks its head, holds it, straightens up
                withAnimation(.spring(duration: 0.4, bounce: 0.35)) {
                    tilt = Bool.random() ? 7 : -7
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 900...1500)))
                withAnimation(.spring(duration: 0.5, bounce: 0.4)) { tilt = 0 }
            case 7: // look around the room — left, right, back to you
                act = .glance(-1)
                try? await Task.sleep(for: .milliseconds(650))
                act = .glance(1)
                try? await Task.sleep(for: .milliseconds(650))
                act = .none
            default: // tiny hop only
                withAnimation(.spring(duration: 0.2, bounce: 0.55)) {
                    hop = -max(2, 3 * size / 100)
                }
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.spring(duration: 0.35, bounce: 0.5)) { hop = 0 }
            }
        }
    }

    /// One activity, start to finish: prop appears, a few beats of motion,
    /// prop leaves. Finite animations only — nothing runs forever.
    private func perform(activity: Activity, sleepy: Bool) async {
        act = .activity(activity)
        onActivity?(activity)
        let beats: Int
        switch activity {
        case .snack: beats = 4
        case .tv: beats = sleepy ? 3 : 5
        case .code: beats = 6
        case .music: beats = 5
        case .stretch: beats = 2
        }
        for _ in 0..<beats {
            guard case .activity = act else { break }
            switch activity {
            case .snack:
                // Lift the snack, bite (squish), settle.
                withAnimation(.easeInOut(duration: 0.28)) { propPhase = 1 }
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.spring(duration: 0.16, bounce: 0.5)) { squish = 0.92 }
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.spring(duration: 0.3, bounce: 0.5)) { squish = 1; propPhase = 0 }
                try? await Task.sleep(for: .milliseconds(520))
            case .tv:
                // Screen flickers; ARCA leans in, then back.
                withAnimation(.easeInOut(duration: 0.5)) { propBeat.toggle(); tilt = propBeat ? 3 : -2 }
                try? await Task.sleep(for: .milliseconds(900))
            case .code:
                // Typing bursts: quick key taps with a little shoulder bob.
                for _ in 0..<4 {
                    withAnimation(.easeOut(duration: 0.06)) { propBeat.toggle(); hop = -max(1, 1.5 * size / 100) }
                    try? await Task.sleep(for: .milliseconds(70))
                    withAnimation(.easeIn(duration: 0.08)) { hop = 0 }
                    try? await Task.sleep(for: .milliseconds(60))
                }
                try? await Task.sleep(for: .milliseconds(320))
            case .music:
                // Head bob to the beat, fins swaying.
                withAnimation(.easeInOut(duration: 0.42)) { propBeat.toggle(); tilt = propBeat ? 6 : -6; bob = propBeat }
                try? await Task.sleep(for: .milliseconds(440))
            case .stretch:
                // Reach up tall, hold, relax.
                withAnimation(.easeInOut(duration: 0.7)) { squish = 1.14; tilt = propBeat ? 4 : -4 }
                try? await Task.sleep(for: .milliseconds(1100))
                withAnimation(.spring(duration: 0.6, bounce: 0.35)) { squish = 1; tilt = 0 }
                propBeat.toggle()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        withAnimation(.spring(duration: 0.4, bounce: 0.3)) { tilt = 0; hop = 0; squish = 1; bob = false; propPhase = 0 }
        if case .activity = act { act = .none }
        onActivity?(nil)
    }

    /// The props: drawn in the body's coordinate space (100 units × s).
    @ViewBuilder
    private func activityProps(_ activity: Activity, s: CGFloat) -> some View {
        switch activity {
        case .snack:
            // A cookie held in the left fin, lifted toward the mouth on each bite.
            ZStack {
                Circle().fill(Color(red: 0.87, green: 0.62, blue: 0.32)).frame(width: 16 * s, height: 16 * s)
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(Color(red: 0.35, green: 0.2, blue: 0.1)).frame(width: 3 * s, height: 3 * s)
                        .offset(x: CGFloat([-3, 3, -1, 4][i]) * s, y: CGFloat([-3, -1, 4, 3][i]) * s)
                }
            }
            .offset(x: -30 * s + propPhase * 14 * s, y: 18 * s - propPhase * 22 * s)
            .rotationEffect(.degrees(Double(propPhase) * -20))
        case .tv:
            // A little TV on the floor in front, screen flickering between colours.
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3 * s)
                    .fill(propBeat ? Color(red: 0.38, green: 0.62, blue: 1) : Color(red: 1, green: 0.55, blue: 0.35))
                    .frame(width: 28 * s, height: 19 * s)
                    .overlay(RoundedRectangle(cornerRadius: 3 * s).strokeBorder(.black.opacity(0.7), lineWidth: 2 * s))
                    .shadow(color: (propBeat ? Color.blue : Color.orange).opacity(0.6), radius: 6 * s)
                Rectangle().fill(.black.opacity(0.7)).frame(width: 8 * s, height: 3 * s)
            }
            .offset(x: 0, y: 44 * s)
        case .code:
            // A laptop, keys lighting up, and glyphs popping off the keyboard.
            ZStack {
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2 * s).fill(Color(red: 0.16, green: 0.17, blue: 0.22))
                        .frame(width: 30 * s, height: 16 * s)
                        .overlay(
                            VStack(alignment: .leading, spacing: 1.5 * s) {
                                ForEach(0..<3, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.4, green: 0.9, blue: 0.6).opacity(propBeat == (i % 2 == 0) ? 0.9 : 0.35))
                                        .frame(width: CGFloat([16, 10, 20][i]) * s, height: 1.6 * s)
                                }
                            }
                            .padding(3 * s), alignment: .topLeading)
                    RoundedRectangle(cornerRadius: 1.5 * s).fill(Color(red: 0.55, green: 0.57, blue: 0.62))
                        .frame(width: 34 * s, height: 3 * s)
                }
                Text(propBeat ? "{ }" : ";")
                    .font(.system(size: max(6, 7 * s), weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.6))
                    .offset(x: 14 * s, y: -16 * s + (propBeat ? -3 * s : 0))
                    .opacity(0.9)
            }
            .offset(y: 42 * s)
        case .music:
            // Headphones over the top, notes floating up and away.
            ZStack {
                Capsule().stroke(Color(red: 0.2, green: 0.2, blue: 0.28), lineWidth: 3 * s)
                    .frame(width: 60 * s, height: 40 * s)
                    .offset(y: -14 * s)
                    .mask(Rectangle().frame(height: 22 * s).offset(y: -22 * s))
                ForEach(0..<2, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3 * s).fill(Color(red: 0.2, green: 0.2, blue: 0.28))
                        .frame(width: 9 * s, height: 13 * s)
                        .offset(x: (i == 0 ? -31 : 31) * s, y: -4 * s)
                }
                Text("♪").font(.system(size: max(8, 11 * s), weight: .bold))
                    .foregroundStyle(skin.hi)
                    .offset(x: 40 * s, y: (propBeat ? -46 : -34) * s)
                    .opacity(propBeat ? 0.3 : 0.95)
                Text("♫").font(.system(size: max(7, 9 * s), weight: .bold))
                    .foregroundStyle(skin.mid)
                    .offset(x: -42 * s, y: (propBeat ? -30 : -44) * s)
                    .opacity(propBeat ? 0.95 : 0.3)
            }
        case .stretch:
            // Sparkle marks at full stretch.
            ForEach(0..<2, id: \.self) { i in
                Image(systemName: "sparkle")
                    .font(.system(size: max(6, 8 * s), weight: .bold))
                    .foregroundStyle(skin.hi.opacity(propBeat ? 0.9 : 0.4))
                    .offset(x: (i == 0 ? -40 : 40) * s, y: (i == 0 ? -28 : -36) * s)
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

/// Attaches a tap gesture only when enabled, so a non-interactive face lets
/// the tap through to whatever container is listening for it.
private struct TapIfInteractive: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        if enabled { content.onTapGesture(perform: action) } else { content }
    }
}


// MARK: - Ignition

/// ARCA catching light — a spark strikes, embers scatter, and the face grows
/// out of the flame.
///
/// This is the first thing a new user sees, and it does the work a static logo
/// can't: the companion *arrives* instead of already being there. The whole
/// sequence runs under a second and a half so it reads as a birth, not a
/// loading screen.
///
/// Wraps `ArcaFace` rather than reimplementing it — once ignition finishes the
/// real face takes over with all its usual idle behavior.
struct ArcaIgnition: View {
    var size: CGFloat = 200
    /// Fires once the face has fully arrived, so a caller can reveal its copy
    /// on the same beat.
    var onArrived: (() -> Void)?

    private enum Stage: Int, Comparable {
        case dark = 0    // nothing yet
        case spark       // a bright point, flickering
        case bloom       // embers throw outward, halo swells
        case arrived     // the face, at full size

        static func < (l: Stage, r: Stage) -> Bool { l.rawValue < r.rawValue }
    }

    @State private var stage: Stage = .dark
    @State private var flicker = false
    /// Fixed per instance so the scatter doesn't reshuffle on re-render.
    @State private var emberAngles: [Double] =
        (0..<9).map { Double($0) / 9 * 360 + Double.random(in: -14...14) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var skin: ArcaSkin { ArcaSkins.current }

    var body: some View {
        ZStack {
            // Heat haze under everything — grows with the stage.
            Circle()
                .fill(skin.mid)
                .frame(width: size * 0.5, height: size * 0.5)
                .blur(radius: size * 0.16)
                .opacity(stage == .dark ? 0 : stage == .spark ? 0.35 : 0.5)
                .scaleEffect(stage == .dark ? 0.2 : stage == .spark ? 0.5 : 1.25)

            if stage < .arrived {
                embers
                spark
            }

            ArcaFace(mood: stage == .arrived ? .happy : .idle, size: size,
                     halo: stage == .arrived, alive: stage == .arrived)
                // Scales up out of the spark rather than fading in, so the
                // flame reads as the thing that becomes the body.
                .scaleEffect(stage == .arrived ? 1 : 0.04)
                .opacity(stage == .arrived ? 1 : 0)
        }
        .frame(width: size, height: size)
        .task { await ignite() }
    }

    /// The initial point of light, flickering while it's alone on screen.
    private var spark: some View {
        Circle()
            .fill(RadialGradient(
                colors: [.white, skin.hi, skin.mid.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: size * (stage == .spark ? 0.09 : 0.2)))
            .frame(width: size * (stage == .spark ? 0.18 : 0.42),
                   height: size * (stage == .spark ? 0.18 : 0.42))
            .scaleEffect(flicker ? 1.18 : 0.86)
            .opacity(stage == .dark ? 0 : stage == .bloom ? 0.7 : 1)
            .shadow(color: skin.hi, radius: size * 0.08)
    }

    /// Sparks thrown outward as the flame takes.
    private var embers: some View {
        ForEach(Array(emberAngles.enumerated()), id: \.offset) { i, angle in
            Circle()
                .fill(i.isMultiple(of: 2) ? skin.hi : Color.white)
                .frame(width: size * 0.028, height: size * 0.028)
                .offset(x: stage == .bloom ? size * 0.42 : 0)
                .rotationEffect(.degrees(angle))
                .opacity(stage == .bloom ? 0 : stage == .spark ? 0.9 : 0)
                .animation(.easeOut(duration: 0.62).delay(Double(i) * 0.012),
                           value: stage)
        }
    }

    private func ignite() async {
        guard !reduceMotion else {
            // Reduced motion still gets an arrival, just without the flame.
            withAnimation(.easeOut(duration: 0.3)) { stage = .arrived }
            onArrived?()
            return
        }

        withAnimation(.easeOut(duration: 0.22)) { stage = .spark }
        withAnimation(.easeInOut(duration: 0.11).repeatForever(autoreverses: true)) {
            flicker = true
        }
        try? await Task.sleep(for: .milliseconds(520))

        withAnimation(.easeOut(duration: 0.34)) { stage = .bloom }
        try? await Task.sleep(for: .milliseconds(300))

        // Overshoot on arrival — the body lands with weight.
        withAnimation(.spring(response: 0.52, dampingFraction: 0.58)) { stage = .arrived }
        try? await Task.sleep(for: .milliseconds(420))
        onArrived?()
    }
}

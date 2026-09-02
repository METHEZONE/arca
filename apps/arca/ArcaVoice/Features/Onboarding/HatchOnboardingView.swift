#if os(macOS)
import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI
import ArcaVoiceKit

/// The Mac first run: a companion is delivered, hatched, named, and woken up.
///
/// Built like a creature-collector's first hour rather than a settings wizard —
/// three quick answers shape the roll, the egg cracks, a rarity banner drops,
/// and every permission is framed as one of the companion's abilities waking
/// up. The generator is deterministic (`CompanionGenesis`), so "다시 뽑기" is a
/// real re-roll and the result is reproducible from what we persist.
struct HatchOnboardingView: View {
    enum Scene: Equatable { case arrival, interview, hatch, reveal, naming, powers, connect, done }
    enum HatchPhase: Equatable { case compress, crack, burst }

    var onFinish: () -> Void

    @State private var scene: Scene = .arrival
    @State private var question = 0
    @State private var pace: CompanionGenesis.Pace?
    @State private var tone: CompanionGenesis.Tone?
    @State private var focus: CompanionGenesis.Focus?
    @State private var salt = 0
    @State private var rerollsLeft = 3
    @State private var spec: CompanionGenesis.Spec?
    @State private var hatchPhase: HatchPhase = .compress
    @State private var companionName = ""
    @State private var ownerName = ""
    @State private var xp = 0
    @State private var confettiStart: Date?

    private let night = Color(red: 0.03, green: 0.05, blue: 0.09)

    private var profile: CompanionGenesis.Profile {
        CompanionGenesis.Profile(pace: pace ?? .steady, tone: tone ?? .warm, focus: focus ?? .meetings)
    }
    private var skin: ArcaSkin {
        ArcaSkins.all.first { $0.id == spec?.skinId } ?? ArcaSkins.all[0]
    }
    private var rarityTint: Color {
        Color(hex: spec?.rarity.tintHex ?? CompanionGenesis.Rarity.common.tintHex)
    }

    var body: some View {
        ZStack {
            NightStage(accent: scene == .arrival || scene == .interview ? ArcaFace.ember : skin.mid)
            switch scene {
            case .arrival: arrival
            case .interview: interview
            case .hatch: hatch
            case .reveal: reveal
            case .naming: naming
            case .powers: powers
            case .connect: connect
            case .done: done
            }
            if let confettiStart {
                ConfettiBurst(start: confettiStart, tint: skin.mid, secondary: rarityTint)
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: 900, minHeight: 640)
        .background(night.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if scene != .done {
                Button(L("건너뛰기", "Skip")) { skipAll() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(18)
            }
        }
        .animation(.spring(duration: 0.55, bounce: 0.18), value: scene)
        .onAppear {
            let stored = UserDefaults.standard.string(forKey: "ownerName") ?? ""
            if stored != "Me" { ownerName = stored }
        }
    }

    // MARK: - Arrival

    private var arrival: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(L("배송 완료", "DELIVERED"))
                .font(.caption.weight(.heavy))
                .tracking(3)
                .foregroundStyle(ArcaFace.ember)
            Text(L("당신에게 컴패니언 하나가 배정됐어요", "A companion has been assigned to you"))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text(L("아직 잠들어 있어요. 깨우기 전에, 어떤 아이가 될지 세 가지만 알려주세요.",
                   "It's still asleep. Before we wake it, tell me three things about who it should become."))
                .font(.title3)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            CoreEggView(phase: nil, tint: ArcaFace.ember)
                .frame(width: 170, height: 210)
                .padding(.vertical, 8)
            Button {
                scene = .interview
            } label: {
                Text(L("상자 열기", "Open the box"))
                    .font(.headline)
                    .padding(.horizontal, 30).padding(.vertical, 13)
                    .background(ArcaFace.ember, in: Capsule())
                    .shadow(color: ArcaFace.ember.opacity(0.5), radius: 12)
            }
            .buttonStyle(.arcaPress)
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    // MARK: - Interview

    private var interview: some View {
        VStack(spacing: 26) {
            Spacer()
            StepDots(count: 3, index: question)
            Group {
                switch question {
                case 0:
                    questionBlock(L("일을 어떻게 처리하는 편이에요?", "How do you like work handled?")) {
                        ForEach(CompanionGenesis.Pace.allCases, id: \.self) { option in
                            ChoiceChip(title: option.label, symbol: option.symbol, selected: pace == option) {
                                pace = option; advance()
                            }
                        }
                    }
                case 1:
                    questionBlock(L("어떻게 말해줬으면 해요?", "How should it talk to you?")) {
                        ForEach(CompanionGenesis.Tone.allCases, id: \.self) { option in
                            ChoiceChip(title: option.label, subtitle: option.sample, symbol: "quote.bubble",
                                       selected: tone == option) {
                                tone = option; advance()
                            }
                        }
                    }
                default:
                    questionBlock(L("가장 먼저 맡기고 싶은 건?", "What should it take off your plate first?")) {
                        ForEach(CompanionGenesis.Focus.allCases, id: \.self) { option in
                            ChoiceChip(title: option.label, symbol: option.symbol, selected: focus == option) {
                                focus = option; advance()
                            }
                        }
                    }
                }
            }
            .id(question)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            Spacer()
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: question)
    }

    private func questionBlock<Options: View>(_ title: String, @ViewBuilder options: () -> Options) -> some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            VStack(spacing: 10) { options() }
                .frame(maxWidth: 520)
        }
    }

    private func advance() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            if question < 2 {
                question += 1
            } else {
                startHatch(fast: false)
            }
        }
    }

    // MARK: - Hatch

    private func startHatch(fast: Bool) {
        spec = CompanionGenesis.generate(profile: profile, salt: salt)
        hatchPhase = .compress
        scene = .hatch
        let scale = fast ? 0.55 : 1.0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(1300 * scale)))
            withAnimation(.linear(duration: 0.08)) { hatchPhase = .crack }
            try? await Task.sleep(for: .milliseconds(Int(1400 * scale)))
            withAnimation(.easeIn(duration: 0.25)) { hatchPhase = .burst }
            try? await Task.sleep(for: .milliseconds(420))
            scene = .reveal
            if spec?.rarity == .legendary || spec?.rarity == .epic { confettiStart = .now }
        }
    }

    private var hatch: some View {
        VStack(spacing: 30) {
            Spacer()
            CoreEggView(phase: hatchPhase, tint: skin.mid)
                .frame(width: 190, height: 235)
            Text(hatchPhase == .compress
                 ? L("무언가 움직여요…", "Something's moving…")
                 : L("깨어나고 있어요!", "It's waking up!"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .contentTransition(.opacity)
            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: - Reveal

    private var reveal: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            ZStack {
                if spec?.rarity == .legendary {
                    LegendaryRing(tint: rarityTint).frame(width: 300, height: 300)
                }
                Circle().fill(skin.mid.opacity(0.14)).frame(width: 260, height: 260)
                ArcaFace(mood: .happy, size: 190, skinOverride: skin, interactive: true)
            }
            .frame(height: 300)
            .transition(.scale(scale: 0.6).combined(with: .opacity))

            RarityBanner(rarity: spec?.rarity ?? .common, tint: rarityTint)
            Text(spec?.archetype ?? "")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
            HStack(spacing: 8) {
                ForEach(spec?.traits ?? [], id: \.self) { TraitChip(text: $0, tint: skin.mid) }
            }
            Text("\(skin.name) · \(skin.flavor)")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))

            HStack(spacing: 12) {
                Button {
                    guard rerollsLeft > 0 else { return }
                    rerollsLeft -= 1
                    salt += 1
                    confettiStart = nil
                    startHatch(fast: true)
                } label: {
                    Label(L("다시 뽑기 \(rerollsLeft)/3", "Re-roll \(rerollsLeft)/3"), systemImage: "dice.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(.white.opacity(rerollsLeft > 0 ? 0.10 : 0.04), in: Capsule())
                        .foregroundStyle(.white.opacity(rerollsLeft > 0 ? 1 : 0.4))
                }
                .buttonStyle(.arcaPress)
                .disabled(rerollsLeft == 0)

                Button {
                    companionName = spec?.nameCandidates.first ?? ""
                    scene = .naming
                } label: {
                    Text(L("이 아이로 할래요", "This one"))
                        .font(.headline)
                        .padding(.horizontal, 26).padding(.vertical, 11)
                        .background(skin.mid, in: Capsule())
                        .shadow(color: skin.mid.opacity(0.5), radius: 10)
                }
                .buttonStyle(.arcaPress)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
            Spacer(minLength: 20)
        }
        .transition(.opacity)
    }

    // MARK: - Naming

    private var naming: some View {
        VStack(spacing: 22) {
            Spacer()
            ArcaFace(mood: companionName.isEmpty ? .idle : .happy, size: 120, skinOverride: skin)
            Text(L("이름을 지어주세요", "Give it a name"))
                .font(.system(size: 28, weight: .bold, design: .rounded))
            HStack(spacing: 8) {
                ForEach(spec?.nameCandidates ?? [], id: \.self) { candidate in
                    Button {
                        withAnimation(.spring(duration: 0.3, bounce: 0.4)) { companionName = candidate }
                    } label: {
                        Text(candidate)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(companionName == candidate ? AnyShapeStyle(skin.mid) : AnyShapeStyle(.white.opacity(0.08)),
                                        in: Capsule())
                    }
                    .buttonStyle(.arcaPress)
                }
            }
            TextField(L("또는 직접 지어주기", "…or type your own"), text: $companionName)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.vertical, 10).padding(.horizontal, 16)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: 360)

            VStack(spacing: 6) {
                Text(L("그리고 당신은요?", "And you are?"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                TextField(L("당신의 이름", "Your name"), text: $ownerName)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8).padding(.horizontal, 14)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 260)
            }

            if !companionName.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("“\(CompanionGenesis.greeting(tone: profile.tone, ownerName: ownerName, companionName: companionName.trimmingCharacters(in: .whitespaces)))”")
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .transition(.opacity)
            }

            Button {
                scene = .powers
            } label: {
                Text(L("이름 붙이기", "Name it"))
                    .font(.headline)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(skin.mid, in: Capsule())
            }
            .buttonStyle(.arcaPress)
            .disabled(companionName.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .animation(.spring(duration: 0.3), value: companionName.isEmpty)
        .transition(.opacity)
    }

    // MARK: - Powers

    private var powers: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                ArcaFace(mood: xp >= 4 ? .happy : .thinking, size: 64, halo: false, skinOverride: skin)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("\(companionName)의 능력을 깨워요", "Wake \(companionName)'s abilities"))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    LevelBar(xp: xp, max: 4, tint: skin.mid)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.top, 28)

            ScrollView {
                VStack(spacing: 12) {
                    PowerCard(power: .brain, tint: skin.mid, onUnlocked: gainXP)
                    PowerCard(power: .ears, tint: skin.mid, onUnlocked: gainXP)
                    PowerCard(power: .eyes, tint: skin.mid, onUnlocked: gainXP)
                    PowerCard(power: .wiki, tint: skin.mid, onUnlocked: gainXP)
                }
                .frame(maxWidth: 720)
                .padding(.vertical, 4)
            }

            Button {
                scene = .connect
            } label: {
                Text(xp >= 4 ? L("다음", "Next") : L("나머지는 나중에", "The rest later"))
                    .font(.headline)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(skin.mid, in: Capsule())
            }
            .buttonStyle(.arcaPress)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 40)
        .transition(.opacity)
    }

    private func gainXP() {
        withAnimation(.spring(duration: 0.5, bounce: 0.4)) { xp += 1 }
    }

    // MARK: - Connect

    private var connect: some View {
        ConnectorQuickConnect(companionName: companionName, tint: skin.mid) {
            scene = .done
            confettiStart = .now
        }
        .transition(.opacity)
    }

    // MARK: - Done

    private var done: some View {
        VStack(spacing: 20) {
            Spacer()
            ArcaFace(mood: .happy, size: 170, skinOverride: skin, interactive: true)
            Text(CompanionGenesis.greeting(tone: profile.tone, ownerName: ownerName,
                                           companionName: companionName.trimmingCharacters(in: .whitespaces)))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("첫 퀘스트", "FIRST QUEST"))
                    .font(.caption.weight(.heavy)).tracking(2)
                    .foregroundStyle(skin.mid)
                Label(firstQuest, systemImage: profile.focus.symbol)
                    .font(.headline)
            }
            .padding(16)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(skin.mid.opacity(0.4)))

            Button {
                finish()
            } label: {
                Text(L("\(companionName)과 시작하기", "Start with \(companionName)"))
                    .font(.headline)
                    .padding(.horizontal, 30).padding(.vertical, 13)
                    .background(skin.mid, in: Capsule())
                    .shadow(color: skin.mid.opacity(0.55), radius: 12)
            }
            .buttonStyle(.arcaPress)
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var firstQuest: String {
        switch profile.focus {
        case .meetings: return L("첫 회의를 녹음해보세요 — 끝나면 요약이 도착해요", "Record your first meeting — a summary lands when it ends")
        case .flow: return L("노치에서 ZONE을 켜고 30분 몰입해보세요", "Turn on ZONE from the notch and focus for 30 minutes")
        case .memory: return L("\(companionName)에게 당신에 대해 세 가지 말해주세요", "Tell \(companionName) three things about yourself")
        case .day: return L("하루 기록을 켜두고 저녁 9시 리포트를 받아보세요", "Leave the day log on and get tonight's 9 PM report")
        }
    }

    // MARK: - Finish

    private func skipAll() {
        if spec == nil { spec = CompanionGenesis.generate(profile: profile, salt: salt) }
        if companionName.isEmpty { companionName = spec?.nameCandidates.first ?? "ARCA" }
        scene = .done
    }

    private func finish() {
        guard let spec else { onFinish(); return }
        let trimmedOwner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOwner.isEmpty { AccountDefaults.set(trimmedOwner, for: "ownerName") }
        HatchedCompanion(
            name: companionName.trimmingCharacters(in: .whitespaces),
            archetype: spec.archetype, traits: spec.traits, rarity: spec.rarity,
            skinId: spec.skinId, seed: spec.seed, profile: profile, hatchedAt: .now
        ).save()
        ArcaSkins.select(skin)
        AccountDefaults.set(true, for: MacOnboarding.onboardedKey)
        onFinish()
    }
}

// MARK: - Powers

enum CompanionPower: CaseIterable {
    case brain, ears, eyes, wiki

    var title: String {
        switch self {
        case .brain: return L("Brain — 기억을 엮어요", "Brain — weaves your memory")
        case .ears: return L("귀 — 회의를 듣고 정리해요", "Ears — listens to meetings and writes them up")
        case .eyes: return L("눈 — 하루의 흐름을 기억해요", "Eyes — remembers the shape of your day")
        case .wiki: return L("위키 — 당신에 대한 책을 써요", "Wiki — writes the book on you")
        }
    }
    var blurb: String {
        switch self {
        case .brain: return L("회의·대화·연결된 앱에서 배운 것을 하나의 기억 그래프로 엮어요. 0순위 능력.",
                              "Everything learned from meetings, chats, and connected apps becomes one memory graph. Ability zero.")
        case .ears: return L("여러 사람이 말해도 누가 말했는지 가려내고, TL;DR·결정·액션 아이템으로 정리해요.",
                             "Tells speakers apart in a room, then writes the TL;DR, decisions, and action items.")
        case .eyes: return L("5분마다 화면을 살짝 보고 어떤 흐름으로 하루를 썼는지 기억해요. 저녁에 하루 리포트가 와요.",
                             "Glances at the screen every five minutes and remembers how the day flowed. A report arrives in the evening.")
        case .wiki: return L("Brain이 자라면 위키도 자라요. 따로 할 일은 없어요.",
                             "Grows on its own as Brain grows. Nothing to do here.")
        }
    }
    var symbol: String {
        switch self {
        case .brain: return "brain.head.profile"
        case .ears: return "waveform"
        case .eyes: return "eye.fill"
        case .wiki: return "book.closed.fill"
        }
    }
}

private struct PowerCard: View {
    enum Status: Equatable { case locked, waking, awake, needsSettings }

    let power: CompanionPower
    let tint: Color
    let onUnlocked: () -> Void

    @State private var status: Status = .locked
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var coach = MacPermissionCoach.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(status == .awake ? tint.opacity(0.25) : .white.opacity(0.06))
                    .frame(width: 46, height: 46)
                Image(systemName: status == .awake ? "checkmark" : power.symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(status == .awake ? tint : .white.opacity(0.75))
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(power.title).font(.headline)
                Text(power.blurb).font(.callout).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                extras
            }
            Spacer()
            actionButton
        }
        .padding(16)
        .background(.white.opacity(status == .awake ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            if status == .awake {
                RoundedRectangle(cornerRadius: 18).strokeBorder(tint.opacity(0.6), lineWidth: 1.5)
                    .shadow(color: tint.opacity(0.4), radius: 8)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: status)
        .onAppear(perform: autoWake)
        .onChange(of: coach.grantedJustNow) { _, granted in
            if power == .eyes, granted == .screenRecording { wake() }
        }
    }

    @ViewBuilder
    private var extras: some View {
        switch power {
        case .brain where status != .awake && KeychainStore.get(.anthropic) == nil:
            SecureField(L("Anthropic API 키 — Brain은 Claude로 생각해요", "Anthropic API key — Brain thinks with Claude"), text: $anthropicKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
        case .ears where KeychainStore.get(.openAI) == nil:
            VStack(alignment: .leading, spacing: 4) {
                Text(L("선택: OpenAI 키가 있으면 다중 화자 분리가 켜져요", "Optional: an OpenAI key turns on multi-speaker separation"))
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
                SecureField("sk-…", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit { saveOpenAI() }
            }
        case .eyes where status == .needsSettings:
            Text(L("시스템 설정 › 화면 기록에서 ARCA를 켜면 자동으로 깨어나요.",
                   "Turn on ARCA under System Settings › Screen Recording and it wakes on its own."))
                .font(.caption).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .awake:
            Text(L("깨어남", "AWAKE"))
                .font(.caption.weight(.heavy))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(tint, in: Capsule())
                .foregroundStyle(.black)
        case .waking:
            ProgressView().controlSize(.small)
        case .locked, .needsSettings:
            Button(action: tap) {
                Text(status == .needsSettings ? L("설정 열기", "Open Settings") : L("깨우기", "Wake"))
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.arcaPress)
        }
    }

    private func autoWake() {
        switch power {
        case .brain where KeychainStore.get(.anthropic) != nil: wake()
        case .ears where MicrophonePermission.isGranted: saveOpenAI(); wake()
        case .eyes where MacPermission.screenRecording.isGranted: enableDayLog(); wake()
        case .wiki: wake()
        default: break
        }
    }

    private func tap() {
        switch power {
        case .brain:
            let key = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            try? KeychainStore.set(key, for: .anthropic)
            wake()
        case .ears:
            saveOpenAI()
            status = .waking
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { wake() } else { status = .needsSettings; coach.begin(.microphone) }
                }
            }
        case .eyes:
            enableDayLog()
            if status == .needsSettings {
                coach.begin(.screenRecording)
                return
            }
            status = .waking
            if CGRequestScreenCaptureAccess() {
                wake()
            } else {
                status = .needsSettings
                Task { @MainActor in
                    for _ in 0..<90 {
                        try? await Task.sleep(for: .seconds(1))
                        if MacPermission.screenRecording.isGranted { wake(); return }
                    }
                }
            }
        case .wiki:
            wake()
        }
    }

    private func saveOpenAI() {
        let key = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try? KeychainStore.set(key, for: .openAI)
        openAIKey = ""
    }

    private func enableDayLog() {
        UserDefaults.standard.set(true, forKey: "dayTrackerEnabled")
    }

    private func wake() {
        guard status != .awake else { return }
        status = .awake
        onUnlocked()
    }
}

// MARK: - Connectors

private struct ConnectorQuickConnect: View {
    let companionName: String
    let tint: Color
    let onNext: () -> Void

    @State private var hub = ConnectorHub()
    @State private var selected: Set<String> = ["GMAIL", "GOOGLECALENDAR", "SLACK", "NOTION", "GOOGLEDRIVE"]
    @State private var pending: Set<String> = []
    @State private var isConnecting = false
    @State private var error: String?
    @State private var obsidianPath = AccountDefaults.string("obsidianVaultPath") ?? ""

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(L("\(companionName)이 볼 수 있는 세계", "The world \(companionName) can see"))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(L("체크하고 한 번만 누르면 순서대로 연결 창이 열려요. 일일이 안 해도 돼요.",
                       "Check what you want and press once — the sign-in windows open in turn. No one-by-one."))
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 28)

            if !hub.isConfigured {
                Text(L("커넥터 허브 키가 아직 없어요. 나중에 설정 › 커넥터에서 Composio 키를 넣으면 바로 연결할 수 있어요.",
                       "No connector-hub key yet. Add a Composio key later in Settings › Connectors and this lights up."))
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: 560)
                    .multilineTextAlignment(.center)
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ConnectorHub.catalog) { connector in
                    ConnectorTile(connector: connector,
                                  state: tileState(connector.slug),
                                  tint: tint) {
                        guard hub.accounts[connector.slug] == nil else { return }
                        if selected.contains(connector.slug) { selected.remove(connector.slug) } else { selected.insert(connector.slug) }
                    }
                }
                obsidianTile
            }
            .frame(maxWidth: 720)
            .disabled(!hub.isConfigured)
            .opacity(hub.isConfigured ? 1 : 0.5)

            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Button(action: connectSelected) {
                    HStack(spacing: 8) {
                        if isConnecting { ProgressView().controlSize(.small) } else { Image(systemName: "link.badge.plus") }
                        Text(L("선택한 \(toConnect.count)개 한 번에 연결", "Connect \(toConnect.count) at once"))
                    }
                    .font(.headline)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(tint, in: Capsule())
                }
                .buttonStyle(.arcaPress)
                .disabled(toConnect.isEmpty || isConnecting || !hub.isConfigured)

                Button(pending.isEmpty && toConnect.isEmpty ? L("다음", "Next") : L("나중에 할게요", "Later")) { onNext() }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12)
            }
            .padding(.bottom, 26)
        }
        .padding(.horizontal, 40)
        .task {
            // A fresh account should be a fresh person to Composio — never inherit
            // the owner's connected accounts through a shared user id.
            if AccountDefaults.string("composioUserId") == nil {
                let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
                AccountDefaults.set("arca-\(suffix)", for: "composioUserId")
            }
            await hub.refresh()
            selected.subtract(Set(hub.accounts.keys))
        }
    }

    private var toConnect: [String] {
        ConnectorHub.catalog.map(\.slug).filter { selected.contains($0) && hub.accounts[$0] == nil }
    }

    private func tileState(_ slug: String) -> ConnectorTile.State {
        if hub.accounts[slug] != nil { return .connected }
        if pending.contains(slug) { return .pending }
        return selected.contains(slug) ? .selected : .idle
    }

    private var obsidianTile: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = L("이 볼트 사용", "Use this vault")
            if panel.runModal() == .OK, let url = panel.url {
                obsidianPath = url.path
                AccountDefaults.set(url.path, for: "obsidianVaultPath")
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: obsidianPath.isEmpty ? "folder" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(obsidianPath.isEmpty ? .white.opacity(0.7) : tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Obsidian").font(.subheadline.weight(.semibold))
                    Text(obsidianPath.isEmpty ? L("볼트 폴더 고르기 (로컬)", "Pick a vault folder (local)") : (obsidianPath as NSString).lastPathComponent)
                        .font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer()
            }
            .padding(12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(obsidianPath.isEmpty ? .white.opacity(0.08) : tint.opacity(0.6)))
        }
        .buttonStyle(.arcaPress)
    }

    private func connectSelected() {
        let slugs = toConnect
        guard !slugs.isEmpty else { return }
        isConnecting = true
        error = nil
        pending.formUnion(slugs)
        Task { @MainActor in
            for (index, slug) in slugs.enumerated() {
                do {
                    let url = try await hub.connectURL(for: slug)
                    NSWorkspace.shared.open(url)
                    if index < slugs.count - 1 { try? await Task.sleep(for: .seconds(1)) }
                } catch {
                    self.error = "\(slug): \(error.localizedDescription)"
                    pending.remove(slug)
                }
            }
            isConnecting = false
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline, !pending.isEmpty {
                await hub.refresh()
                pending.subtract(Set(hub.accounts.keys))
                selected.subtract(Set(hub.accounts.keys))
                if pending.isEmpty { break }
                try? await Task.sleep(for: .seconds(3))
            }
            if !pending.isEmpty {
                self.error = L("아직 연결이 안 된 앱이 있어요 — 브라우저 창을 확인해 주세요.", "Some apps aren't connected yet — check the browser windows.")
            }
        }
    }
}

private struct ConnectorTile: View {
    enum State { case idle, selected, pending, connected }
    let connector: ConnectorInfo
    let state: State
    let tint: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Group {
                    switch state {
                    case .connected: Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
                    case .pending: ProgressView().controlSize(.small)
                    case .selected: Image(systemName: "checkmark.square.fill").foregroundStyle(tint)
                    case .idle: Image(systemName: "square").foregroundStyle(.white.opacity(0.4))
                    }
                }
                .font(.title3)
                .frame(width: 24)
                Image(systemName: connector.symbol).foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.displayName).font(.subheadline.weight(.semibold))
                    Text(state == .connected ? L("연결됨", "Connected") : state == .pending ? L("연결 중…", "Connecting…") : " ")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
            .padding(12)
            .background(.white.opacity(state == .idle ? 0.04 : 0.07), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(state == .idle ? .white.opacity(0.08) : tint.opacity(0.6)))
        }
        .buttonStyle(.arcaPress)
    }
}

// MARK: - Stage pieces

/// Deep-night backdrop with slow drifting embers.
private struct NightStage: View {
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                for i in 0..<42 {
                    let seed = Double(i) * 12.9898
                    let x = (sin(seed) * 0.5 + 0.5) * size.width
                    let speed = 6 + (cos(seed * 1.7) * 0.5 + 0.5) * 10
                    let y = size.height - ((t * speed + seed * 37).truncatingRemainder(dividingBy: size.height + 40)) + 20
                    let r = 1.2 + (sin(seed * 3.1) * 0.5 + 0.5) * 2.2
                    let alpha = 0.10 + (sin(t * 0.8 + seed) * 0.5 + 0.5) * 0.25
                    canvas.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                                with: .color(accent.opacity(alpha)))
                }
            }
        }
        .background(
            RadialGradient(colors: [accent.opacity(0.18), .clear], center: .center, startRadius: 40, endRadius: 520)
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: accent)
    }
}

struct EggShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + h * 0.62),
                   control1: CGPoint(x: r.minX + w * 0.86, y: r.minY),
                   control2: CGPoint(x: r.maxX, y: r.minY + h * 0.30))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.minY + h * 0.95),
                   control2: CGPoint(x: r.minX + w * 0.78, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.62),
                   control1: CGPoint(x: r.minX + w * 0.22, y: r.maxY),
                   control2: CGPoint(x: r.minX, y: r.minY + h * 0.95))
        p.addCurve(to: CGPoint(x: r.midX, y: r.minY),
                   control1: CGPoint(x: r.minX, y: r.minY + h * 0.30),
                   control2: CGPoint(x: r.minX + w * 0.14, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// The egg: idle bob when `phase` is nil, then compress → crack (shake, fissures) → burst.
private struct CoreEggView: View {
    let phase: HatchOnboardingView.HatchPhase?
    let tint: Color

    @State private var bob = false
    @State private var shakeTick = 0

    var body: some View {
        ZStack {
            Ellipse()
                .fill(tint.opacity(phase == nil ? 0.25 : 0.45))
                .frame(width: 150, height: 26)
                .blur(radius: 8)
                .offset(y: 110)
            EggShape()
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.95, blue: 0.90),
                                              Color(red: 0.85, green: 0.78, blue: 0.70),
                                              Color(red: 0.55, green: 0.45, blue: 0.38)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(EggShape().fill(RadialGradient(colors: [tint.opacity(phase == .compress || phase == .crack ? 0.55 : 0.15), .clear],
                                                        center: .center, startRadius: 10, endRadius: 120)))
                .overlay(speckles)
                .overlay { if phase == .crack || phase == .burst { cracks } }
                .shadow(color: tint.opacity(phase == nil ? 0.35 : 0.8), radius: phase == nil ? 18 : 40)
            if phase == .burst {
                Circle().fill(.white).blur(radius: 30).scaleEffect(2.2).opacity(0.9)
            }
        }
        .scaleEffect(phase == .compress ? 0.94 : phase == .burst ? 1.25 : 1)
        .opacity(phase == .burst ? 0 : 1)
        .rotationEffect(.degrees(phase == .crack ? (shakeTick % 2 == 0 ? -5 : 5) : 0))
        .offset(x: phase == .crack ? (shakeTick % 2 == 0 ? -6 : 6) : 0,
                y: phase == nil ? (bob ? -6 : 6) : 0)
        .animation(phase == nil ? .easeInOut(duration: 2.2).repeatForever(autoreverses: true) : .default, value: bob)
        .animation(.spring(duration: 0.35), value: phase)
        .task(id: phase) {
            if phase == nil { bob = true }
            guard phase == .crack else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(70))
                withAnimation(.linear(duration: 0.07)) { shakeTick += 1 }
            }
        }
    }

    private var speckles: some View {
        Canvas { canvas, size in
            for i in 0..<14 {
                let s = Double(i) * 7.31
                let x = (sin(s) * 0.5 + 0.5) * size.width * 0.7 + size.width * 0.15
                let y = (cos(s * 1.3) * 0.5 + 0.5) * size.height * 0.7 + size.height * 0.15
                let r = 2 + (sin(s * 2) * 0.5 + 0.5) * 3
                canvas.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(tint.opacity(0.35)))
            }
        }
        .clipShape(EggShape())
    }

    private var cracks: some View {
        Canvas { canvas, size in
            var p = Path()
            p.move(to: CGPoint(x: size.width * 0.52, y: size.height * 0.18))
            p.addLine(to: CGPoint(x: size.width * 0.44, y: size.height * 0.34))
            p.addLine(to: CGPoint(x: size.width * 0.58, y: size.height * 0.46))
            p.addLine(to: CGPoint(x: size.width * 0.47, y: size.height * 0.62))
            p.move(to: CGPoint(x: size.width * 0.44, y: size.height * 0.34))
            p.addLine(to: CGPoint(x: size.width * 0.28, y: size.height * 0.40))
            p.move(to: CGPoint(x: size.width * 0.58, y: size.height * 0.46))
            p.addLine(to: CGPoint(x: size.width * 0.74, y: size.height * 0.50))
            canvas.stroke(p, with: .color(.white), lineWidth: 2.2)
            canvas.stroke(p, with: .color(tint.opacity(0.8)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
        }
        .blendMode(.plusLighter)
    }
}

private struct RarityBanner: View {
    let rarity: CompanionGenesis.Rarity
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Image(systemName: i < rarity.stars ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(i < rarity.stars ? tint : .white.opacity(0.2))
            }
            Text(rarity.label)
                .font(.caption.weight(.heavy))
                .tracking(2.5)
                .foregroundStyle(tint)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.5)))
        .shadow(color: tint.opacity(rarity == .legendary ? 0.7 : 0.25), radius: rarity == .legendary ? 14 : 4)
    }
}

private struct LegendaryRing: View {
    let tint: Color
    @State private var angle = 0.0

    var body: some View {
        Circle()
            .strokeBorder(AngularGradient(colors: [tint, .white.opacity(0.1), tint.opacity(0.6), .white, tint],
                                          center: .center), lineWidth: 3)
            .rotationEffect(.degrees(angle))
            .blur(radius: 0.5)
            .onAppear { withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { angle = 360 } }
    }
}

private struct TraitChip: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(tint.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
    }
}

private struct ChoiceChip: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(selected ? .black : .white.opacity(0.85))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(selected ? .black.opacity(0.6) : .white.opacity(0.5))
                    }
                }
                Spacer()
            }
            .foregroundStyle(selected ? .black : .white)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(selected ? AnyShapeStyle(ArcaFace.ember) : AnyShapeStyle(.white.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(selected ? 0 : 0.10)))
        }
        .buttonStyle(.arcaPress)
    }
}

private struct StepDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? ArcaFace.ember : .white.opacity(0.15))
                    .frame(width: i == index ? 26 : 8, height: 8)
            }
        }
        .animation(.spring(duration: 0.35), value: index)
    }
}

private struct LevelBar: View {
    let xp: Int
    let max: Int
    let tint: Color
    var body: some View {
        HStack(spacing: 10) {
            Text(xp >= max ? "Lv.2" : "Lv.1")
                .font(.caption.weight(.heavy))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(xp) / CGFloat(Swift.max(max, 1)))
                        .shadow(color: tint.opacity(0.6), radius: 6)
                }
            }
            .frame(height: 8)
            Text("\(xp)/\(max) XP")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: 360)
    }
}

/// A 2.4s confetti burst from the top-center, drawn with a seeded scatter.
private struct ConfettiBurst: View {
    let start: Date
    let tint: Color
    let secondary: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                guard t < 2.6 else { return }
                for i in 0..<110 {
                    let s = Double(i) * 0.6180339887
                    let angle = (s.truncatingRemainder(dividingBy: 1)) * .pi * 2
                    let speed = 260 + (sin(s * 9) * 0.5 + 0.5) * 380
                    let x = size.width / 2 + cos(angle) * speed * t * 0.55
                    let y = size.height * 0.28 + sin(angle) * speed * t * 0.35 + 520 * t * t
                    let w = 6 + (cos(s * 5) * 0.5 + 0.5) * 6
                    let alpha = Swift.max(0, 1 - t / 2.4)
                    let color = i % 3 == 0 ? Color.white : (i % 3 == 1 ? tint : secondary)
                    var rect = Path()
                    rect.addRoundedRect(in: CGRect(x: -w / 2, y: -w / 4, width: w, height: w / 2), cornerSize: CGSize(width: 1, height: 1))
                    var ctx = canvas
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(t * 6 + s * 10))
                    ctx.fill(rect, with: .color(color.opacity(alpha)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
#endif

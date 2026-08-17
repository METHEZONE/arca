#if os(iOS)
import SwiftUI
import AVFoundation
import ArcaVoiceKit

/// First-run flow for someone who has never used ARCA and holds no API keys.
///
/// The previous version was written for the personal build — it told the user
/// their keys were "already configured", which is only true on a device the
/// developer set up. Everything here works for a stranger instead: they say
/// what to call them, grant the microphone, and get a trial balance ARCA
/// spends on their behalf. No keys, no account setup, no trip to Settings.
///
/// Four pages is the ceiling. Each one either collects something the app
/// genuinely needs or earns the next tap; none of them is a tour.

/// ARCA's accent is whatever coat the spirit is currently wearing — Ember
/// (`#f75b2b`) out of the box. These screens used to hardcode `ArcaTheme.pixel`
/// (cyan), which fought the orange face right above the button. Reading the
/// live skin keeps the CTA matched to the character and follows a skin change.
private var accent: Color { ArcaSkins.current.mid }

struct OnboardingView: View {
    var onDone: () -> Void

    @AppStorage("ownerName") private var ownerName = ""
    @AppStorage("companionName") private var companionName = ""
    @State private var page = 0
    @State private var typedName = ""
    @State private var micAsked = false
    @State private var typedCompanion = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var companionFocused: Bool

    private let pageCount = 5

    #if DEBUG
    /// `-onboardingPage 2` opens straight to that page. Reviewing this flow
    /// otherwise means tapping through it on every rebuild, and the Simulator
    /// window is not reliably scriptable. Debug builds only.
    private static var debugStartPage: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-onboardingPage"),
              i + 1 < args.count, let n = Int(args[i + 1]) else { return 0 }
        return n
    }
    #endif

    var body: some View {
        ZStack {
            ArcaTheme.spiritNight.ignoresSafeArea()

            TabView(selection: $page) {
                MeetPage(action: advance).tag(0)
                NamePage(name: $typedName, focused: $nameFocused, action: commitName).tag(1)
                HatchPage(name: $typedCompanion, focused: $companionFocused,
                          action: commitCompanion).tag(2)
                MicPage(asked: micAsked, action: requestMic).tag(3)
                CreditPage(action: finish).tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                Spacer()
                PageDots(count: pageCount, current: page)
                    .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            typedName = ownerName
            typedCompanion = companionName
            // Start the picker on whatever the account already wears, so
            // re-running onboarding resumes rather than resets.
            #if DEBUG
            if Self.debugStartPage > 0 { page = min(Self.debugStartPage, pageCount - 1) }
            #endif
        }
    }

    private func advance() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            page = min(page + 1, pageCount - 1)
        }
    }

    private func commitName() {
        let trimmed = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        // The name labels this user's turns in every transcript, so an empty
        // one has to fall back to something the notes can actually print.
        ownerName = trimmed.isEmpty ? "나" : trimmed
        nameFocused = false
        advance()
    }

    /// Locks in the companion the user just built. Selection is committed here
    /// rather than live on every arrow tap so backing out of the page doesn't
    /// leave a half-chosen creature persisted.
    private func commitCompanion() {
        let trimmed = typedCompanion.trimmingCharacters(in: .whitespacesAndNewlines)
        companionName = trimmed.isEmpty ? "ARCA" : trimmed
        companionFocused = false
        advance()
    }

    private func requestMic() {
        micAsked = true
        Task {
            _ = await AVAudioApplication.requestRecordPermission()
            // Advance either way: a denial is recoverable from Settings, and
            // stranding the user on this page is worse than letting them in.
            await MainActor.run { advance() }
        }
    }

    private func finish() {
        TrialCredit.grantIfNeeded()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onDone()
    }
}

// MARK: - Page 1 · who ARCA is

private struct MeetPage: View {
    let action: () -> Void

    /// Copy and CTA wait for the flame to finish so the arrival isn't
    /// competing with text for attention.
    @State private var arrived = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ArcaIgnition(size: 200) {
                withAnimation(.easeOut(duration: 0.45)) { arrived = true }
            }
            VStack(spacing: 12) {
                Text("저는 ARCA예요")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("회의든 혼잣말이든, 제 얼굴을 누르면 듣기 시작해요.\n말한 걸 받아적고 기억해뒀다가 필요할 때 꺼내드릴게요.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : 10)
            Spacer()
            OnboardingCTA(title: "시작하기", action: action)
                .opacity(arrived ? 1 : 0)
        }
        .padding(.vertical, 50)
    }
}

// MARK: - Page 2 · what to call you

private struct NamePage: View {
    @Binding var name: String
    var focused: FocusState<Bool>.Binding
    let action: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            SpiritFace(mood: .idle, size: 120)
            VStack(spacing: 10) {
                Text("뭐라고 부를까요?")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("녹취록에서 회원님 발언을 이 이름으로 표시해요.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }

            TextField("", text: $name, prompt: Text("이름").foregroundStyle(.white.opacity(0.3)))
                .focused(focused)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // Without this iOS reads the field as a contact-name field and
                // floats an AutoFill chip over the subtitle above it.
                .textContentType(.none)
                .submitLabel(.done)
                .onSubmit(action)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(accent.opacity(focused.wrappedValue ? 0.6 : 0.2), lineWidth: 1)
                )
                .padding(.horizontal, 48)

            Spacer()
            OnboardingCTA(title: "다음", action: action)
        }
        .padding(.vertical, 50)
    }
}

// MARK: - Page 3 · hatch your companion

/// Silhouette, coat, and name in one screen.
///
/// This is the page that turns a downloaded app into *my* companion — the
/// thing that makes leaving cost something. Everything it offers already
/// exists in the design system (4 forms × 6 skins), so picking is browsing,
/// not configuring.
private struct HatchPage: View {
    @Binding var name: String
    var focused: FocusState<Bool>.Binding
    let action: () -> Void


    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Text("이름을 지어주세요")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            ArcaFace(mood: .happy, size: 170)
                .frame(maxWidth: .infinity)

            TextField("", text: $name,
                      prompt: Text("이름 지어주기").foregroundStyle(.white.opacity(0.3)))
                .focused(focused)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.none)
                .submitLabel(.done)
                .onSubmit(action)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(accent.opacity(focused.wrappedValue ? 0.6 : 0.2), lineWidth: 1)
                )
                .padding(.horizontal, 56)

            Spacer(minLength: 8)
            OnboardingCTA(title: "이 아이로 할게요", action: action)
        }
        .padding(.vertical, 40)
    }


}


// MARK: - Page 4 · microphone

private struct MicPage: View {
    let asked: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(accent)
            VStack(spacing: 10) {
                Text("마이크를 열어주세요")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("듣지 않으면 받아적을 수가 없어요.\n녹음은 회원님이 누를 때만 시작합니다.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }

            PrivacyNote()

            Spacer()
            OnboardingCTA(title: asked ? "계속" : "마이크 허용", action: action)
        }
        .padding(.vertical, 50)
    }
}

private struct PrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(accent)
                .padding(.top, 2)
            Text("녹음 파일은 이 기기에 남아요. 받아적는 동안에만 서버를 거칩니다.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 36)
    }
}

// MARK: - Page 4 · trial balance

private struct CreditPage: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            SpiritFace(mood: .happy, size: 140)
            VStack(spacing: 10) {
                Text("녹음은 무제한이에요")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("받아적고 정리하는 비용은 제가 낼게요.\nAPI 키 같은 건 준비하지 않으셔도 돼요.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            ReadyCard()

            Spacer()
            OnboardingCTA(title: "첫 녹음 하러 가기", prominent: true, action: action)
        }
        .padding(.vertical, 50)
    }
}

private struct ReadyCard: View {
    /// Recording is deliberately listed as unlimited and chat as the metered
    /// one — the trial should never make someone hesitate to hit record.
    private var items: [(icon: String, text: String, free: Bool)] {
        [
            ("infinity", "녹음과 받아적기 — 무제한", true),
            ("infinity", "회의 요약·결정사항·할 일", true),
            ("bubble.left.and.text.bubble.right", "ARCA와 \(TrialCredit.grantLabel())", false),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(items, id: \.text) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.footnote)
                        .foregroundStyle(item.free ? accent : .white.opacity(0.5))
                        .frame(width: 20)
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(item.free ? 0.85 : 0.6))
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 36)
    }
}

// MARK: - Shared chrome

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? accent : Color.white.opacity(0.25))
                    .frame(width: i == current ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
    }
}

private struct OnboardingCTA: View {
    let title: String
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(accent, in: Capsule())
                .shadow(color: accent.opacity(0.5), radius: prominent ? 20 : 10, y: 4)
        }
        .padding(.horizontal, 32)
    }
}

#Preview {
    OnboardingView(onDone: {})
}
#endif

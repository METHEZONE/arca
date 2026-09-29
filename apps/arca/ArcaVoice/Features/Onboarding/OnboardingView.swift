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

    private let pageCount = 6

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
                AccountPage { name in
                    if let name, typedName.isEmpty { typedName = name }
                    advance()
                }.tag(1)
                NamePage(name: $typedName, focused: $nameFocused, action: commitName).tag(2)
                HatchPage(name: $typedCompanion, focused: $companionFocused,
                          action: commitCompanion).tag(3)
                MicPage(asked: micAsked, action: requestMic).tag(4)
                // The beta is the core loop (talk, record, "대신 처리할까요?"),
                // so the Health ask waits for the condition screen itself.
                CreditPage(action: finish).tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                Spacer()
                PageDots(count: pageCount, current: page)
                    .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: page) { _, step in BrainClient.track("onboarding_step_\(step)") }
        .onAppear {
            BrainClient.track("onboarding_step_0")
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
        BrainClient.track("onboarding_completed")
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
                Text(L("저는 ARCA예요", "I'm ARCA"))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(L("말한 걸 기억하고, 할 일은 대신 해 드려요.", "I remember what you say and handle the to-dos."))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : 10)
            Spacer()
            OnboardingCTA(title: L("시작하기", "Get started"), action: action)
                .opacity(arrived ? 1 : 0)
        }
        .padding(.vertical, 50)
    }
}

// MARK: - Page 2 · an account (optional)

/// Google sign-in, skippable. With it the iPhone and the Mac share one memory
/// and the tester has a name on the metrics; without it everything still works
/// on a per-device account.
private struct AccountPage: View {
    let onDone: (_ googleName: String?) -> Void
    @State private var working = false
    @State private var signedInAs: String?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            SpiritFace(mood: signedInAs == nil ? .idle : .happy, size: 120)
            VStack(spacing: 10) {
                Text(signedInAs == nil ? L("계정을 만들까요?", "Create an account?") : L("연결됐어요", "You're in"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(signedInAs ?? L("로그인하면 아이폰과 맥이 같은 기억을 써요.", "Sign in and your iPhone and Mac share one memory."))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if failed {
                    Text(L("로그인하지 못했어요. 나중에 다시 해 주세요.", "Couldn't sign in. Try again later."))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            Spacer()
            VStack(spacing: 14) {
                if signedInAs == nil {
                    OnboardingCTA(title: working ? L("여는 중…", "Opening…") : L("Google로 계속하기", "Continue with Google"), prominent: true) {
                        guard !working else { return }
                        working = true
                        failed = false
                        Task { @MainActor in
                            let account = await GoogleSignIn.shared.signIn()
                            working = false
                            if let account {
                                signedInAs = account.email
                                try? await Task.sleep(for: .seconds(1))
                                onDone(account.name)
                            } else {
                                failed = true
                            }
                        }
                    }
                    Button(L("나중에", "Not now")) { onDone(nil) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.bottom, 54)
        }
    }
}

// MARK: - Page 3 · what to call you

private struct NamePage: View {
    @Binding var name: String
    var focused: FocusState<Bool>.Binding
    let action: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            SpiritFace(mood: .idle, size: 120)
            VStack(spacing: 10) {
                Text(L("뭐라고 부를까요?", "What should I call you?"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(L("녹취록에 이 이름으로 표시해요.", "This is how you appear in transcripts."))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }

            TextField("", text: $name, prompt: Text(L("이름", "Name")).foregroundStyle(.white.opacity(0.3)))
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
            OnboardingCTA(title: L("다음", "Next"), action: action)
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

            Text(L("이름을 지어주세요", "Give me a name"))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            ArcaFace(mood: .happy, size: 170)
                .frame(maxWidth: .infinity)

            TextField("", text: $name,
                      prompt: Text(L("이름 지어주기", "Name me")).foregroundStyle(.white.opacity(0.3)))
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
            OnboardingCTA(title: L("이 아이로 할게요", "That's the one"), action: action)
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
                Text(L("마이크를 열어주세요", "Turn on the mic"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(L("녹음은 누를 때만 시작해요.", "Recording starts only when you tap."))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }

            
            Spacer()
            OnboardingCTA(title: asked ? L("계속", "Continue") : L("마이크 허용", "Allow mic"), action: action)
        }
        .padding(.vertical, 50)
    }
}

// MARK: - Page 6 · ready

private struct CreditPage: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            SpiritFace(mood: .happy, size: 140)
            VStack(spacing: 10) {
                Text(L("준비됐어요", "You're all set"))
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(L("녹음은 무제한이고, 비용은 제가 낼게요.", "Recording is unlimited, and it's on me."))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
            OnboardingCTA(title: L("첫 녹음 하러 가기", "Make your first recording"), prominent: true, action: action)
        }
        .padding(.vertical, 50)
    }
}

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

#if os(iOS)
import SwiftUI

/// kip!-style, share-first onboarding: three fast pages that get the user
/// sharing something into ARCA as quickly as possible. Persisting "seen
/// onboarding" is the caller's job — we just call `onDone()`.
struct OnboardingView: View {
    var onDone: () -> Void

    @State private var page = 0
    private let pageCount = 3

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.05, blue: 0.09)
                .ignoresSafeArea()

            TabView(selection: $page) {
                MeetArcaPage(action: advance)
                    .tag(0)
                ShareAnythingPage(action: advance)
                    .tag(1)
                DynamicIslandPage(action: onDone)
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                HStack {
                    Spacer()
                    Button("Skip", action: onDone)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                Spacer()
                PageDots(count: pageCount, current: page)
                    .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func advance() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            page = min(page + 1, pageCount - 1)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? ArcaTheme.pixel : Color.white.opacity(0.25))
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
                .background(ArcaTheme.pixel, in: Capsule())
                .shadow(color: ArcaTheme.pixel.opacity(0.5), radius: prominent ? 20 : 10, y: 4)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Page 1

private struct MeetArcaPage: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            SpiritFace(mood: .idle, size: 200)
            VStack(spacing: 12) {
                Text("I'm ARCA.")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Tap my face on Home and I'll listen — meetings, ideas, anything. I transcribe, remember, and act.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            Spacer()
            OnboardingCTA(title: "Continue", action: action)
        }
        .padding(.bottom, 60)
        .padding(.top, 40)
    }
}

// MARK: - Page 2

private struct ShareAnythingPage: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)
            VStack(spacing: 10) {
                Text("Share anything to me")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("The fastest way to hand something to ARCA: the share sheet you already use every day.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            MockShareSheetRow()

            VStack(alignment: .leading, spacing: 14) {
                InstructionStep(number: 1, text: "Take a screenshot or hit Share in any app")
                InstructionStep(number: 2, text: "Pick ARCA — I'll read it and draft the action plan.")
            }
            .padding(.horizontal, 34)

            Text("Tip: pin me — share sheet → scroll the app row → More → Edit → add ARCA to Favorites.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            Spacer()
            OnboardingCTA(title: "Continue", action: action)
        }
        .padding(.bottom, 60)
        .padding(.top, 40)
    }
}

private struct MockShareSheetRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SpiritFace(size: 36)
            Text("ARCA")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ArcaTheme.pixel.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 40)
    }
}

private struct InstructionStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(ArcaTheme.pixel, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Page 3

private struct DynamicIslandPage: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 10)
            SpiritFace(mood: .happy, size: 140)
            VStack(spacing: 10) {
                Text("I live in your Dynamic Island")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("I stay up top while we work — glance for status, tap to talk.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            ChecklistCard()

            Spacer()
            OnboardingCTA(title: "Let's go", prominent: true, action: action)
        }
        .padding(.bottom, 60)
        .padding(.top, 40)
    }
}

private struct ChecklistCard: View {
    private let items = [
        "API keys — already configured",
        "Share extension — ready",
        "Recording — one tap away",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ArcaTheme.pixel)
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 36)
    }
}

#Preview {
    OnboardingView(onDone: {})
}
#endif

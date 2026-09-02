#if os(macOS)
import SwiftData
import SwiftUI
import ArcaVoiceKit

/// Decides, per account, whether the Mac shows the hatch flow or the home.
///
/// The flag is account-scoped, so a freshly added account meets its own
/// companion while the owner's account is untouched. Accounts that already
/// hold recordings are grandfathered in on first launch after the update —
/// nobody who has used ARCA for months gets walked through a first run.
/// Namespace for the flag, kept off the generic view so callers can name it.
enum MacOnboarding {
    static let onboardedKey = "macOnboarded"
}

struct MacOnboardingGate<Content: View>: View {

    @Environment(\.modelContext) private var modelContext
    @State private var showOnboarding: Bool?
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            switch showOnboarding {
            case .some(true):
                HatchOnboardingView {
                    withAnimation(.easeInOut(duration: 0.5)) { showOnboarding = false }
                }
            case .some(false):
                content()
            case .none:
                Color(red: 0.03, green: 0.05, blue: 0.09)
                    .ignoresSafeArea()
                    .onAppear(perform: decide)
            }
        }
    }

    private func decide() {
        if AccountDefaults.bool(MacOnboarding.onboardedKey) == true {
            showOnboarding = false
            return
        }
        let existing = (try? modelContext.fetchCount(FetchDescriptor<RecordingSession>())) ?? 0
        if existing > 0 {
            AccountDefaults.set(true, for: MacOnboarding.onboardedKey)
            showOnboarding = false
            return
        }
        showOnboarding = true
    }
}
#endif

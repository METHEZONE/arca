import SwiftUI
import ArcaVoiceKit

/// The one empty state every screen uses: ARCA, a title, one sentence, and at
/// most one thing to do. Three different empty-state styles across five tabs
/// was a large part of why the app read as unfinished.
struct ArcaEmptyState: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var actionSymbol: String = "arrow.right"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ArcaFace(mood: .idle, size: 84, halo: true)
                .frame(width: 100, height: 100)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionSymbol)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(ArcaFace.ember, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.arcaPress)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import AuthenticationServices
import Foundation
import ArcaVoiceKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "Google로 계속하기": the in-app sheet for ARCA Cloud's Google sign-in.
///
/// This install's device token rides along, so the server claims the device
/// for the Google account during the callback — no code to copy into a web
/// page. The server ends the flow at `arca://linked?email=…`, which is what
/// closes the sheet.
@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleSignIn()

    struct Account { let email: String; let name: String? }

    private var session: ASWebAuthenticationSession?

    /// nil when the user closed the sheet, Google refused, or the cloud was
    /// unreachable — onboarding carries on without an account either way.
    func signIn() async -> Account? {
        guard let token = await ArcaCloudAccount.linkCode(),
              var components = URLComponents(url: ArcaConfig.cloudEndpoint("api/arca/auth/google"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "flow", value: "native"),
                                 URLQueryItem(name: "device", value: token)]
        guard let url = components.url else { return nil }

        let account: Account? = await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "arca") { callback, _ in
                let items = callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                let value = { (name: String) in items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
                guard value("error") == nil, let email = value("email") else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Account(email: email, name: value("name")))
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(returning: nil) }
        }
        session = nil
        if let account {
            AccountDefaults.set(account.email, for: "cloudAccountEmail")
            Analytics.signedIn(email: account.email)
            BrainClient.track("account_linked")
        }
        return account
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            #endif
        }
    }
}

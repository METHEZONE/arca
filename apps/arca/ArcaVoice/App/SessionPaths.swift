import Foundation
import ArcaVoiceKit

enum SessionPaths {
    static var sessionsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let accountId = AccountStore.currentAccountId()
        if AccountStore.isDefault(accountId) {
            return base.appendingPathComponent("ArcaVoice/sessions", isDirectory: true)
        }
        return base
            .appendingPathComponent("ArcaVoice", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func directory(for name: String) -> URL {
        sessionsRoot.appendingPathComponent(name, isDirectory: true)
    }

    static func resolve(relativePath: String) -> URL {
        sessionsRoot.appendingPathComponent(relativePath)
    }
}

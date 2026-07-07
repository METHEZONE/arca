import Foundation

enum SessionPaths {
    static var sessionsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ArcaVoice/sessions", isDirectory: true)
    }

    static func directory(for name: String) -> URL {
        sessionsRoot.appendingPathComponent(name, isDirectory: true)
    }

    static func resolve(relativePath: String) -> URL {
        sessionsRoot.appendingPathComponent(relativePath)
    }
}

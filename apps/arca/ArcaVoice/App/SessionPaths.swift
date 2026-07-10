import Foundation
import ArcaVoiceKit

enum SessionPaths {
    /// 테스트 빌드(ARCA Test)는 본편 데이터를 절대 건드리지 않도록
    /// Application Support 하위 폴더를 통째로 분리한다.
    static var rootFolderName: String {
        #if ARCA_TEST_BUILD
        return "ArcaVoiceTest"
        #else
        return "ArcaVoice"
        #endif
    }

    static var sessionsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let accountId = AccountStore.currentAccountId()
        if AccountStore.isDefault(accountId) {
            return base.appendingPathComponent("\(rootFolderName)/sessions", isDirectory: true)
        }
        return base
            .appendingPathComponent(rootFolderName, isDirectory: true)
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

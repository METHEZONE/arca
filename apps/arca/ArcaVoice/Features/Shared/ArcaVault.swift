import Foundation
import ArcaVoiceKit

/// Where ARCA writes markdown. Every account has a vault whether or not
/// Obsidian is installed: by default `~/Documents/ARCA`, created on first use
/// with a fixed folder layout, so what ARCA learns is always readable as
/// plain files. Linking an Obsidian vault in Connectors moves the same layout
/// under `<vault>/ARCA/` instead — the structure is identical either way.
///
///   ARCA/
///   ├─ README.md            what each folder holds
///   ├─ <meeting notes>.md   one per recorded meeting (legacy flat layout)
///   ├─ Daily/               the nightly day note
///   ├─ Memory/Memories.md   everything in the memory brain, grouped by kind
///   ├─ Notes/               documents ARCA wrote in chat ("save as note")
///   └─ Wiki/                the wiki ARCA maintains about the owner
enum ArcaVault {
    static let defaultRootName = "ARCA"

    /// The vault root chosen in Connectors, or nil when none is linked.
    static var linkedRoot: URL? {
        guard let path = AccountDefaults.string("obsidianVaultPath")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }

    /// `~/Documents/ARCA` (per account: `~/Documents/ARCA/<account>` for the
    /// non-default ones), created on demand.
    static var defaultRoot: URL {
        var url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(defaultRootName, isDirectory: true)
        let account = AccountStore.currentAccountId()
        if !AccountStore.isDefault(account) {
            url = url.appendingPathComponent(account, isDirectory: true)
        }
        return url
    }

    /// The folder ARCA writes into: `<linked vault>` when Obsidian is linked
    /// (its notes land under `ARCA/` inside it), else the default root's
    /// parent so the same `ARCA/` layout applies. Always exists after this call.
    static func resolvedRoot() -> URL {
        if let linked = linkedRoot { return linked }
        let root = defaultRoot
        ensureLayout(at: root.appendingPathComponent(""))
        return root.deletingLastPathComponent()
    }

    /// The `ARCA/` folder inside the resolved root, with its subfolders.
    static func arcaFolder() -> URL {
        let folder = resolvedRoot().appendingPathComponent(arcaFolderName(), isDirectory: true)
        ensureLayout(at: folder)
        return folder
    }

    /// Inside a linked Obsidian vault the folder is plain `ARCA/`; in the
    /// default location the account-scoped root already is the ARCA folder.
    private static func arcaFolderName() -> String {
        linkedRoot != nil ? defaultRootName : defaultRoot.lastPathComponent
    }

    static func folder(_ name: Subfolder) -> URL {
        let url = arcaFolder().appendingPathComponent(name.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    enum Subfolder: String { case daily = "Daily", memory = "Memory", notes = "Notes", wiki = "Wiki" }

    private static func ensureLayout(at folder: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for sub in [Subfolder.daily, .memory, .notes, .wiki] {
            try? fm.createDirectory(at: folder.appendingPathComponent(sub.rawValue, isDirectory: true), withIntermediateDirectories: true)
        }
        let readme = folder.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            # ARCA

            ARCA가 배운 것과 쓴 것이 여기에 마크다운으로 쌓입니다. Obsidian이 없어도 그대로 읽을 수 있고, \
            Obsidian 볼트를 연결하면 그 볼트 안 `ARCA/` 폴더에 같은 구조로 씁니다.

            - `*.md` — 회의 하나당 회의록 하나 (요약·결정·액션 아이템)
            - `Daily/` — 저녁에 정리되는 하루 기록
            - `Memory/Memories.md` — 메모리 브레인 전체, 종류별로
            - `Notes/` — 대화에서 ARCA가 써서 저장한 문서
            - `Wiki/` — ARCA가 당신에 대해 정리한 위키

            이 폴더는 언제든 옮기거나 지워도 됩니다. ARCA의 원본 데이터는 앱 안에 따로 있어요.
            """
            try? Data(text.utf8).write(to: readme)
        }
    }
}

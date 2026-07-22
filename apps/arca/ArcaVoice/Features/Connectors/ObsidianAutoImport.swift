#if os(macOS)
import Foundation
import SwiftData
import ArcaVoiceKit

/// Pulls the Obsidian vault into ARCA's memory automatically — the importer
/// used to run only from a manual button in 커넥터, so the memory graph never
/// picked the vault up on its own. Failures surface as a notch notice instead
/// of dying silently (the usual causes: vault path not set in THIS app's
/// settings, or macOS folder permission not granted to this build).
@MainActor
enum ObsidianAutoImport {
    private static let importEvery: TimeInterval = 6 * 3600

    static func runIfDue(context: ModelContext, now: Date = .now) async {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: "obsidianLastAutoImportAt")
        guard now.timeIntervalSince1970 - last > importEvery else { return }

        let path = AccountDefaults.string("obsidianVaultPath")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            // Remind once per launch cycle, not every heartbeat.
            defaults.set(now.timeIntervalSince1970, forKey: "obsidianLastAutoImportAt")
            AppServices.shared.notch.showNotice(
                "옵시디언 볼트 경로가 이 앱에 설정돼 있지 않아요 — 설정에서 지정하면 기억으로 가져올게요", seconds: 8)
            return
        }

        let vault = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        do {
            let result = try ObsidianImporter.importVault(from: vault, context: context)
            defaults.set(now.timeIntervalSince1970, forKey: "obsidianLastAutoImportAt")
            DebugTrace.log("obsidian auto-import: \(result.imported) new, \(result.skipped) known")
            if result.imported > 0 {
                AppServices.shared.notch.showNotice(
                    "옵시디언에서 기억 \(result.imported)개를 가져왔어요", seconds: 5)
            } else if result.imported == 0 && result.skipped == 0 {
                // Directory exists but zero markdown files came back — with a
                // real vault that means macOS blocked the read.
                AppServices.shared.notch.showNotice(
                    "옵시디언 볼트를 읽지 못했어요 — 시스템 설정 > 개인정보 보호 > 파일 및 폴더에서 ARCA 접근을 확인해 주세요", seconds: 10)
            }
        } catch {
            defaults.set(now.timeIntervalSince1970, forKey: "obsidianLastAutoImportAt")
            AppServices.shared.notch.showNotice(
                "옵시디언 가져오기 실패 — \(error.localizedDescription)", seconds: 8)
            DebugTrace.log("obsidian auto-import failed: \(error)")
        }
    }
}
#endif

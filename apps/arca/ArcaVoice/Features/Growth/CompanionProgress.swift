import Foundation
import SwiftUI
import ArcaVoiceKit

/// The pet-raising layer: XP and coins earned by actually using ARCA, a level
/// derived from XP, and what the companion owns. Per account, in
/// AccountDefaults, so a fresh account starts at Lv.1 with one coat.
///
/// Every award traces to a real event (a meeting summarized, a report
/// delivered, a to-do done) — there is no tapping for coins. That's the
/// difference between a companion that grows with your work and a slot machine.
@MainActor
@Observable
final class CompanionProgress {
    static let shared = CompanionProgress()

    enum Event: String, CaseIterable {
        case meetingSummarized, chatTurn, memoryLearned, dayReport, todoDone, insightWoven, noteSaved, browserTask

        var xp: Int {
            switch self {
            case .meetingSummarized: return 30
            case .chatTurn: return 3
            case .memoryLearned: return 2
            case .dayReport: return 20
            case .todoDone: return 6
            case .insightWoven: return 12
            case .noteSaved: return 8
            case .browserTask: return 10
            }
        }
        var coins: Int {
            switch self {
            case .meetingSummarized: return 12
            case .chatTurn: return 1
            case .memoryLearned: return 0
            case .dayReport: return 8
            case .todoDone: return 3
            case .insightWoven: return 5
            case .noteSaved: return 3
            case .browserTask: return 4
            }
        }
        var label: String {
            switch self {
            case .meetingSummarized: return L("회의 요약 완료", "Meeting summarized")
            case .chatTurn: return L("대화", "Chat turn")
            case .memoryLearned: return L("새 기억", "New memory")
            case .dayReport: return L("하루 리포트", "Day report")
            case .todoDone: return L("할 일 완료", "To-do done")
            case .insightWoven: return L("인사이트 엮기", "Insight woven")
            case .noteSaved: return L("노트 저장", "Note saved")
            case .browserTask: return L("브라우저 작업", "Browser task")
            }
        }
    }

    struct State: Codable {
        var xp = 0
        var coins = 0
        var ownedSkinIds: [String] = ["ember"]
        var counts: [String: Int] = [:]
        var lastAward: Date?
    }

    private(set) var state = State()
    /// The most recent award, for a brief "+30 XP" toast on the home.
    private(set) var lastToast: (event: Event, at: Date)?

    private static let key = "companionProgress"

    private init() { load() }

    var level: Int { 1 + state.xp / 120 }
    var xpIntoLevel: Int { state.xp % 120 }
    var xpPerLevel: Int { 120 }
    var coins: Int { state.coins }
    var ownedSkinIds: Set<String> { Set(state.ownedSkinIds) }

    func count(_ event: Event) -> Int { state.counts[event.rawValue] ?? 0 }

    func award(_ event: Event) {
        state.xp += event.xp
        state.coins += event.coins
        state.counts[event.rawValue, default: 0] += 1
        state.lastAward = .now
        lastToast = (event, .now)
        save()
    }

    /// Buying a coat: false when the wallet is short.
    @discardableResult
    func buySkin(_ skinId: String, price: Int) -> Bool {
        guard !ownedSkinIds.contains(skinId) else { return true }
        guard state.coins >= price else { return false }
        state.coins -= price
        state.ownedSkinIds.append(skinId)
        save()
        return true
    }

    func owns(skinId: String) -> Bool { ownedSkinIds.contains(skinId) }

    /// Called when the account changes: forget the old account's wallet.
    func reload() { load() }

    private func load() {
        var loaded = State()
        if let raw = AccountDefaults.string(Self.key), let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            loaded = decoded
        }
        // Whatever the companion wears at first launch is theirs.
        if !loaded.ownedSkinIds.contains(SkinPalette.current.id) {
            loaded.ownedSkinIds.append(SkinPalette.current.id)
        }
        state = loaded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state), let raw = String(data: data, encoding: .utf8) {
            AccountDefaults.set(raw, for: Self.key)
        }
    }
}

/// Coat prices by mood of the palette — the originals are cheap, the rare
/// glows cost a few good weeks of work.
enum SkinPricing {
    static func price(for skinId: String) -> Int {
        switch skinId {
        case "ember": return 0
        case "tide", "moss": return 60
        case "blossom": return 90
        case "aurum": return 140
        case "wisp": return 180
        default: return 80
        }
    }
}

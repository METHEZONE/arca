import Foundation
import Observation
import ArcaVoiceKit

/// Observable wrapper around `ArcaLanguageResolver` so a language change rebuilds
/// the UI without a relaunch.
///
/// The resolver and the `L(_:_:)` helper itself live in `ArcaVoiceCore`, because
/// user-facing copy isn't only in views — score labels, durations and error
/// messages are computed inside the package and have to speak the same language
/// as the screen around them.
@MainActor
@Observable
final class ArcaLanguage {
    static let shared = ArcaLanguage()

    typealias Choice = ArcaLanguageChoice

    private(set) var choice: Choice
    /// Bumped on every change so the root view can rebuild and pick up new copy.
    private(set) var generation = 0

    private init() {
        choice = ArcaLanguageResolver.stored()
    }

    func set(_ choice: Choice) {
        guard choice != self.choice else { return }
        self.choice = choice
        ArcaLanguageResolver.apply(choice)
        generation += 1
    }

    nonisolated static var isKorean: Bool { ArcaLanguageResolver.isKorean }
}

import Foundation
import ArcaVoiceCore

/// LLM-backed meeting intelligence. Implementations: Anthropic (default), OpenAI.
/// Keys are user-owned (BYOK) and live in the Keychain — there is no server.
public protocol Summarizer: Sendable {
    func summarize(_ transcript: AttributedTranscript, userNotes: String?, style: NoteStyle)
        async throws -> MeetingNotes
}

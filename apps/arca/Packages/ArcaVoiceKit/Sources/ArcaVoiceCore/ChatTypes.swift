import Foundation

/// One turn in a conversation with ARCA. Content can mix text and images
/// (a dragged/captured screenshot the user is asking about).
public struct ChatMessage: Identifiable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public struct Part: Sendable {
        public enum Kind: Sendable { case text, image }
        public var kind: Kind
        public var text: String?
        public var imageData: Data?
        public var mediaType: String?

        public static func text(_ value: String) -> Part {
            Part(kind: .text, text: value, imageData: nil, mediaType: nil)
        }
        public static func image(_ data: Data, mediaType: String = "image/jpeg") -> Part {
            Part(kind: .image, text: nil, imageData: data, mediaType: mediaType)
        }
    }

    public let id: UUID
    public var role: Role
    public var parts: [Part]
    /// True while an assistant turn is still streaming/pending.
    public var isPending: Bool

    public init(id: UUID = UUID(), role: Role, parts: [Part], isPending: Bool = false) {
        self.id = id
        self.role = role
        self.parts = parts
        self.isPending = isPending
    }

    /// Plain-text rendering of the message (images noted inline).
    public var displayText: String {
        parts.compactMap { part in
            switch part.kind {
            case .text: return part.text
            case .image: return "🖼️"
            }
        }.joined(separator: " ")
    }
}

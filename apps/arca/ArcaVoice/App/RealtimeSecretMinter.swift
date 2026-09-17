#if os(iOS)
import Foundation
import SwiftData
import ArcaVoiceKit

/// Mints a short-lived OpenAI Realtime client secret for the Watch, with
/// ARCA's persona and what it already knows about the owner baked into the
/// session — so the wrist gets ARCA, not a generic voice, and never holds a
/// long-lived key. Own key when there is one, ARCA Cloud for invited testers.
enum RealtimeSecretMinter {
    struct Secret {
        let value: String
        let expiresAt: Date
    }

    enum MintError: LocalizedError {
        case noCredentials
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return L("아이폰 ARCA에 OpenAI 키나 초대 코드가 필요해요 (설정)", "ARCA on your iPhone needs an OpenAI key or an invite code (Settings)")
            case .http(let status, let body):
                return L("대화 세션을 못 열었어요 (HTTP \(status)): \(body)", "Couldn't open a talk session (HTTP \(status)): \(body)")
            }
        }
    }

    static func mint(instructions: String) async throws -> Secret {
        let session: [String: Any] = [
            "type": "realtime",
            "model": "gpt-realtime",
            "instructions": instructions,
            "audio": ["output": ["voice": "marin"]],
        ]
        let body: [String: Any] = [
            "expires_after": ["anchor": "created_at", "seconds": 600],
            "session": session,
        ]
        var request: URLRequest
        if let key = KeychainStore.get(.openAI), !key.isEmpty {
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/client_secrets")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if let invite = ArcaCloud.inviteToken {
            request = URLRequest(url: ArcaCloud.baseURL.appendingPathComponent("realtime/secret"))
            request.setValue(invite, forHTTPHeaderField: "x-api-key")
        } else {
            throw MintError.noCredentials
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 20
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["value"] as? String else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw MintError.http(status, message)
        }
        let expires = (json["expires_at"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? Date.now.addingTimeInterval(600)
        return Secret(value: value, expiresAt: expires)
    }

    /// ARCA on the wrist: brief, in the owner's language, and already
    /// acquainted — the durable facts from memory ride along.
    @MainActor
    static func instructions(context: ModelContext?, ownerName: String) -> String {
        var lines = [
            "너는 ARCA, \(ownerName)의 컴패니언이야. 지금 \(ownerName)이 애플워치로 짧게 음성 대화를 하고 있어.",
            "한국어로, 한두 문장으로 짧고 따뜻하게 답해. 긴 설명은 하지 말고, 필요하면 한 가지만 되물어.",
            "부탁받은 할 일이나 결정은 또렷하게 한 문장으로 다시 말해줘 — 나중에 기록으로 남아.",
        ]
        if !ArcaLanguageResolver.isKorean {
            lines = [
                "You are ARCA, \(ownerName)'s companion. \(ownerName) is talking to you briefly on an Apple Watch.",
                "Answer in one or two warm sentences. No long explanations; ask at most one follow-up question.",
                "Restate any to-do or decision you are asked to keep in one clear sentence — it becomes a record.",
            ]
        }
        if let context {
            var descriptor = FetchDescriptor<MemoryFact>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            descriptor.fetchLimit = 40
            let facts = ((try? context.fetch(descriptor)) ?? []).map(\.text)
            if !facts.isEmpty {
                lines.append("")
                lines.append(ArcaLanguageResolver.isKorean ? "네가 이미 아는 것들:" : "What you already know:")
                lines += facts.prefix(40).map { "- \($0)" }
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif

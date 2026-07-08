import Foundation
import ArcaVoiceCore

/// The arca-brain relay: a private GitHub repo used as a tiny cross-device
/// datastore. Devices push/pull `tasks.json` via the contents API — no server
/// of our own, durable, versioned, and browsable as a repo.
public struct GitHubRelay: Sendable {
    let token: String
    let repo: String

    /// nil when the device has no relay token/repo configured.
    public init?() {
        guard let token = KeychainStore.get(.github), !token.isEmpty,
              let repo = UserDefaults.standard.string(forKey: "relayRepo"), !repo.isEmpty
        else { return nil }
        self.token = token
        self.repo = repo
    }

    public struct Remote<T: Codable & Sendable>: Sendable {
        public var value: T?
        /// Blob SHA required to update the file (nil = file doesn't exist yet).
        public var sha: String?
    }

    public enum RelayError: Error, LocalizedError {
        case api(Int, String)
        case conflict

        public var errorDescription: String? {
            switch self {
            case .api(let status, let message): return "Relay failed (HTTP \(status)): \(String(message.prefix(120)))"
            case .conflict: return "Relay conflict — retrying"
            }
        }
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/contents/\(path)")!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return r
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Lists a directory: (filename, blob sha) pairs; empty when absent.
    public func listDirectory(path: String) async throws -> [(name: String, sha: String)] {
        let (data, response) = try await URLSession.shared.data(for: request(path))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return [] }
        guard (200..<300).contains(status),
              let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw RelayError.api(status, String(data: data, encoding: .utf8) ?? "")
        }
        return items.compactMap { item in
            guard let name = item["name"] as? String,
                  let sha = item["sha"] as? String else { return nil }
            return (name, sha)
        }
    }

    /// Fetches and decodes a JSON file from the repo (value nil on 404).
    public func pull<T: Codable & Sendable>(_ type: T.Type, path: String) async throws -> Remote<T> {
        let (data, response) = try await URLSession.shared.data(for: request(path))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return Remote(value: nil, sha: nil) }
        guard (200..<300).contains(status) else {
            throw RelayError.api(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String,
              let b64 = (json["content"] as? String)?
                  .replacingOccurrences(of: "\n", with: ""),
              let blob = Data(base64Encoded: b64)
        else { throw RelayError.api(status, "unexpected contents payload") }
        let value = try Self.decoder().decode(T.self, from: blob)
        return Remote(value: value, sha: sha)
    }

    /// Fetches a file's raw bytes (nil on 404). Uses the raw media type so
    /// blobs over the 1MB inline-JSON limit (audio) still come through.
    public func pullRaw(path: String) async throws -> Data? {
        var r = request(path)
        r.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else {
            throw RelayError.api(status, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Writes raw bytes (audio, images) to the repo. Same sha/conflict
    /// semantics as `push`. GitHub caps contents-API files at 100MB.
    @discardableResult
    public func pushRaw(_ blob: Data, path: String, sha: String?,
                        message: String) async throws -> String {
        var body: [String: Any] = [
            "message": message,
            "content": blob.base64EncodedString(),
        ]
        if let sha { body["sha"] = sha }
        var r = request(path, method: "PUT")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: r, body: payload)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 409 || status == 422 { throw RelayError.conflict }
        guard (200..<300).contains(status) else {
            throw RelayError.api(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [String: Any],
              let newSha = content["sha"] as? String
        else { throw RelayError.api(status, "no sha in response") }
        return newSha
    }

    /// Encodes and writes a JSON file. Pass the sha from the last pull; a stale
    /// sha means another device wrote first → RelayError.conflict (re-pull,
    /// re-merge, retry).
    @discardableResult
    public func push<T: Codable & Sendable>(_ value: T, path: String, sha: String?,
                                            message: String) async throws -> String {
        let blob = try Self.encoder().encode(value)
        var body: [String: Any] = [
            "message": message,
            "content": blob.base64EncodedString(),
        ]
        if let sha { body["sha"] = sha }
        var r = request(path, method: "PUT")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: r, body: payload)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 409 || status == 422 { throw RelayError.conflict }
        guard (200..<300).contains(status) else {
            throw RelayError.api(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [String: Any],
              let newSha = content["sha"] as? String
        else { throw RelayError.api(status, "no sha in response") }
        return newSha
    }
}

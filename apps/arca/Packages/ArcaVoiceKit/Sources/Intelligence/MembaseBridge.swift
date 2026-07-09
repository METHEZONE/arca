import Foundation

public enum MembaseBridgeError: LocalizedError, Sendable {
    case reauthenticationRequired
    case http(Int, String)
    case malformedResponse(String)
    case toolUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .reauthenticationRequired:
            return "재인증 필요 — Claude에서 membase 사용 시 자동 갱신됨"
        case .http(let status, let message):
            return "membase 요청 실패 (\(status)): \(message)"
        case .malformedResponse(let message):
            return "membase 응답을 읽을 수 없습니다: \(message)"
        case .toolUnavailable(let name):
            return "membase 도구를 찾을 수 없습니다: \(name)"
        }
    }
}

public struct MembaseImportDeduplication: Sendable, Equatable {
    public let newTexts: [String]
    public let skippedCount: Int

    public init(newTexts: [String], skippedCount: Int) {
        self.newTexts = newTexts
        self.skippedCount = skippedCount
    }
}

public struct MembaseBridge: Sendable {
    public let endpoint: URL
    public let authRoot: URL

    public init(
        endpoint: URL = URL(string: "https://mcp.membase.so/mcp")!,
        authRoot: URL? = nil
    ) {
        self.endpoint = endpoint
        self.authRoot = authRoot ?? Self.defaultAuthRoot
    }

    public static var defaultAuthRoot: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mcp-auth", isDirectory: true)
        #else
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(".mcp-auth", isDirectory: true)
        #endif
    }

    public func importRecentMemories(limit: Int) async throws -> [String] {
        #if os(macOS)
        let tokenFiles = Self.candidateTokenFiles(in: authRoot)
        guard !tokenFiles.isEmpty else { throw MembaseBridgeError.reauthenticationRequired }

        var sawUnauthorized = false
        var lastError: Error?

        for file in tokenFiles {
            guard let token = Self.accessToken(in: file) else { continue }
            do {
                return try await importRecentMemories(limit: limit, token: token)
            } catch MembaseBridgeError.http(401, _) {
                sawUnauthorized = true
                continue
            } catch {
                lastError = error
                continue
            }
        }

        if sawUnauthorized || lastError == nil {
            throw MembaseBridgeError.reauthenticationRequired
        }
        throw lastError ?? MembaseBridgeError.reauthenticationRequired
        #else
        throw MembaseBridgeError.reauthenticationRequired
        #endif
    }

    public static func candidateTokenFiles(in authRoot: URL,
                                           fileManager: FileManager = .default) -> [URL] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: authRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let remoteDirectories = directories
            .filter { url in
                guard url.lastPathComponent.hasPrefix("mcp-remote-") else { return false }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true
            }
            .sorted { lhs, rhs in
                compareVersions(lhs.lastPathComponent, rhs.lastPathComponent)
            }

        return remoteDirectories.flatMap { directory in
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return files
                .filter { $0.lastPathComponent.hasSuffix("_tokens.json") }
                .sorted { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                    return lhs.lastPathComponent < rhs.lastPathComponent
                }
        }
    }

    public static func finalJSONRPCPayload(from data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MembaseBridgeError.malformedResponse("non-UTF8 body")
        }

        var lastDataLine: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard value != "[DONE]", !value.isEmpty else { continue }
            lastDataLine = String(value)
        }

        if let lastDataLine {
            return Data(lastDataLine.utf8)
        }
        return data
    }

    public static func memoryTexts(fromToolText text: String) -> [String] {
        var memories: [String] = []
        var current: [String] = []

        func flush() {
            let value = current
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                memories.append(value)
            }
            current.removeAll()
        }

        for line in text.components(separatedBy: .newlines) {
            if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flush()
                current.append(String(line[match.upperBound...]))
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        flush()
        return memories
    }

    public static func deduplicate(incoming: [String], existing: Set<String>) -> MembaseImportDeduplication {
        var seen = existing
        var newTexts: [String] = []
        var skipped = 0

        for text in incoming {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !seen.contains(trimmed) else {
                skipped += 1
                continue
            }
            seen.insert(trimmed)
            newTexts.append(trimmed)
        }

        return MembaseImportDeduplication(newTexts: newTexts, skippedCount: skipped)
    }

    private func importRecentMemories(limit: Int, token: String) async throws -> [String] {
        let sessionID = try await initialize(token: token)
        try await postNotification(method: "notifications/initialized", token: token, sessionID: sessionID)
        let tools = try await request(ToolsListResult.self, method: "tools/list", params: EmptyParams(),
                                      token: token, sessionID: sessionID, id: 2)
        guard tools.tools.contains(where: { $0.name == "search_memory" }) else {
            throw MembaseBridgeError.toolUnavailable("search_memory")
        }

        var offset = 0
        var collected: [String] = []
        let target = max(limit, 0)
        while collected.count < target {
            let pageLimit = min(30, target - collected.count)
            guard pageLimit > 0 else { break }
            let params = ToolCallParams(
                name: "search_memory",
                arguments: SearchMemoryArguments(query: "", limit: pageLimit, offset: offset)
            )
            let result = try await request(ToolCallResult.self, method: "tools/call", params: params,
                                           token: token, sessionID: sessionID, id: 3 + offset)
            let texts = result.content
                .filter { $0.type == "text" }
                .flatMap { Self.memoryTexts(fromToolText: $0.text) }
            guard !texts.isEmpty else { break }
            collected.append(contentsOf: texts)
            if texts.count < pageLimit { break }
            offset += texts.count
        }

        return Array(collected.prefix(target))
    }

    private func initialize(token: String) async throws -> String? {
        let params = InitializeParams(
            protocolVersion: "2025-06-18",
            capabilities: EmptyObject(),
            clientInfo: ClientInfo(name: "arca", version: "1.0")
        )
        var request = baseRequest(token: token, sessionID: nil)
        request.httpBody = try JSONEncoder().encode(RPCRequest(id: 1, method: "initialize", params: params))
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response, data: data)
        _ = try decodeRPC(InitializeResult.self, data: data)
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "mcp-session-id")
    }

    private func postNotification(method: String, token: String, sessionID: String?) async throws {
        var request = baseRequest(token: token, sessionID: sessionID)
        request.httpBody = try JSONEncoder().encode(RPCNotification(method: method))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 202 || (200..<300).contains(http.statusCode) else {
            try checkHTTP(response, data: data)
            return
        }
    }

    private func request<Result: Decodable, Params: Encodable>(
        _ resultType: Result.Type,
        method: String,
        params: Params,
        token: String,
        sessionID: String?,
        id: Int
    ) async throws -> Result {
        var request = baseRequest(token: token, sessionID: sessionID)
        request.httpBody = try JSONEncoder().encode(RPCRequest(id: id, method: method, params: params))
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response, data: data)
        return try decodeRPC(resultType, data: data)
    }

    private func baseRequest(token: String, sessionID: String?) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionID, !sessionID.isEmpty {
            request.setValue(sessionID, forHTTPHeaderField: "mcp-session-id")
        }
        return request
    }

    private func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MembaseBridgeError.malformedResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw MembaseBridgeError.http(http.statusCode, String(message.prefix(300)))
        }
    }

    private func decodeRPC<Result: Decodable>(_ resultType: Result.Type, data: Data) throws -> Result {
        let payload = try Self.finalJSONRPCPayload(from: data)
        let envelope = try JSONDecoder().decode(RPCResponse<Result>.self, from: payload)
        if let error = envelope.error {
            throw MembaseBridgeError.http(0, error.message)
        }
        guard let result = envelope.result else {
            throw MembaseBridgeError.malformedResponse("missing JSON-RPC result")
        }
        return result
    }

    private static func accessToken(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let token = try? JSONDecoder().decode(TokenFile.self, from: data).accessToken,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func compareVersions(_ lhsName: String, _ rhsName: String) -> Bool {
        let lhs = versionComponents(from: lhsName)
        let rhs = versionComponents(from: rhsName)
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return lhsName > rhsName
    }

    private static func versionComponents(from name: String) -> [Int] {
        name
            .replacingOccurrences(of: "mcp-remote-", with: "")
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}

private struct TokenFile: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct EmptyObject: Encodable {}
private struct EmptyParams: Encodable {}

private struct RPCRequest<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

private struct RPCNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
}

private struct RPCResponse<Result: Decodable>: Decodable {
    let result: Result?
    let error: RPCError?
}

private struct RPCError: Decodable {
    let code: Int
    let message: String
}

private struct InitializeParams: Encodable {
    let protocolVersion: String
    let capabilities: EmptyObject
    let clientInfo: ClientInfo
}

private struct ClientInfo: Encodable {
    let name: String
    let version: String
}

private struct InitializeResult: Decodable {
    let protocolVersion: String
}

private struct ToolsListResult: Decodable {
    let tools: [Tool]

    struct Tool: Decodable {
        let name: String
    }
}

private struct ToolCallParams: Encodable {
    let name: String
    let arguments: SearchMemoryArguments
}

private struct SearchMemoryArguments: Encodable {
    let query: String
    let limit: Int
    let offset: Int
}

private struct ToolCallResult: Decodable {
    let content: [Content]

    struct Content: Decodable {
        let type: String
        let text: String
    }
}

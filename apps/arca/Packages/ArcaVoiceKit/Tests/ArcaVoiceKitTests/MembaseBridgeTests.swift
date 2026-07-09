import Foundation
import Testing
import ArcaVoiceKit

@Suite struct MembaseBridgeTests {
    @Test func ordersNewestMCPRemoteVersionDirectoriesFirst() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = root.appendingPathComponent("mcp-remote-0.1.37", isDirectory: true)
        let newDir = root.appendingPathComponent("mcp-remote-0.1.38", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)

        let oldToken = oldDir.appendingPathComponent("old_tokens.json")
        let firstNewToken = newDir.appendingPathComponent("first_tokens.json")
        let latestNewToken = newDir.appendingPathComponent("latest_tokens.json")
        try #"{"access_token":"old"}"#.write(to: oldToken, atomically: true, encoding: .utf8)
        try #"{"access_token":"first"}"#.write(to: firstNewToken, atomically: true, encoding: .utf8)
        try #"{"access_token":"latest"}"#.write(to: latestNewToken, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)],
                                              ofItemAtPath: firstNewToken.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)],
                                              ofItemAtPath: latestNewToken.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 30)],
                                              ofItemAtPath: oldToken.path)

        let ordered = MembaseBridge.candidateTokenFiles(in: root).map(\.lastPathComponent)

        #expect(ordered == ["latest_tokens.json", "first_tokens.json", "old_tokens.json"])
    }

    @Test func parsesFinalSSEDataFrameAsJSONRPCPayload() throws {
        let sse = """
        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"step":"first"}}

        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"step":"final","count":2}}

        """

        let payload = try MembaseBridge.finalJSONRPCPayload(from: Data(sse.utf8))
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])

        #expect(result["step"] as? String == "final")
        #expect(result["count"] as? Int == 2)
    }

    @Test func deduplicatesImportedMemoryTextAgainstExistingFactsAndBatchDuplicates() {
        let existing: Set<String> = ["already known"]
        let result = MembaseBridge.deduplicate(
            incoming: ["already known", "new fact", " new fact ", "", "another fact"],
            existing: existing
        )

        #expect(result.newTexts == ["new fact", "another fact"])
        #expect(result.skippedCount == 2)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MembaseBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

import Foundation
import Testing
@testable import ArcaVoiceKit

@Suite struct MailAddressTests {
    @Test func extractsAngleBracketAddress() {
        #expect(MailAddress.address(from: "(주)엘케이랩코리아 <lklab@lklabkorea.co.kr>")
                == "lklab@lklabkorea.co.kr")
    }

    @Test func bareAddressPassesThrough() {
        #expect(MailAddress.address(from: " me@thezonebio.com ") == "me@thezonebio.com")
    }

    @Test func nestedBracketsUseLastPair() {
        #expect(MailAddress.address(from: "\"Weird <name>\" <real@x.com>") == "real@x.com")
    }

    @Test func nonAddressYieldsEmpty() {
        #expect(MailAddress.address(from: "no reply here") == "")
    }

    @Test func malformedShapesAreRefusedNotGuessed() {
        // The result is a literal send target — anything not shaped like one
        // address must come back empty.
        #expect(MailAddress.address(from: "notifications@github.com via SendGrid") == "")
        #expect(MailAddress.address(from: "박민성 <me@thezonebio.com") == "")
        #expect(MailAddress.address(from: "a@b@c.com") == "")
        #expect(MailAddress.address(from: "@no-local.com") == "")
        #expect(MailAddress.address(from: "no-domain@") == "")
        #expect(MailAddress.address(from: "Name <not an address>") == "")
    }
}

// Serialized: mutates shared UserDefaults keys that other tests may read.
@Suite(.serialized) struct DocumentVaultTests {
    private func makeVault(files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, name) in files.enumerated() {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            // Stagger modification dates so ordering is deterministic.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(index) * 10)],
                ofItemAtPath: url.path)
        }
        return dir
    }

    @Test func listsAttachableFilesNewestFirstAndResolvesExactName() throws {
        let dir = try makeVault(files: ["사업자등록증.png", "사업자등록증 제조 최신.pdf",
                                        "notes.txt", "통장사본.jpeg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        UserDefaults.standard.set(dir.path, forKey: DocumentVault.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: DocumentVault.defaultsKey) }

        let names = DocumentVault.entries().map(\.name)
        // .txt is not attachable; newest (largest staggered date) comes first.
        #expect(names == ["통장사본.jpeg", "사업자등록증 제조 최신.pdf", "사업자등록증.png"])

        let resolved = DocumentVault.resolve("사업자등록증 제조 최신.pdf")
        #expect(resolved?.name == "사업자등록증 제조 최신.pdf")
        #expect(DocumentVault.resolve("없는 파일.pdf") == nil)
        #expect(DocumentVault.resolve("") == nil)
    }

    @Test func mimeTypesMapByExtension() {
        #expect(DocumentVault.mimeType(for: URL(fileURLWithPath: "/a/b.pdf")) == "application/pdf")
        #expect(DocumentVault.mimeType(for: URL(fileURLWithPath: "/a/b.PNG")) == "image/png")
        #expect(DocumentVault.mimeType(for: URL(fileURLWithPath: "/a/b.hwp")) == "application/x-hwp")
        #expect(DocumentVault.mimeType(for: URL(fileURLWithPath: "/a/b.weird")) == "application/octet-stream")
    }
}

// Serialized: mutates shared UserDefaults keys that other tests may read.
@Suite(.serialized) struct ArcaLangTests {
    @Test func pinnedLanguageWins() {
        UserDefaults.standard.set("en", forKey: ArcaLang.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ArcaLang.defaultsKey) }
        #expect(ArcaLang.code == "en")
        #expect(L("Tasks", ko: "할 일") == "Tasks")

        UserDefaults.standard.set("ko", forKey: ArcaLang.defaultsKey)
        #expect(ArcaLang.code == "ko")
        #expect(ArcaLang.promptLanguageName == "Korean")
        #expect(L("Tasks", ko: "할 일") == "할 일")
    }
}

import Foundation
import Testing
@testable import ArcaVoiceCore

@Suite struct AccountScopingTests {
    @Test func firstRunCreatesDefaultAccountFromLegacyDefaults() throws {
        let directory = try temporaryDirectory()
        let defaults = try temporaryDefaults()
        defaults.set("Min", forKey: "ownerName")
        defaults.set("me@example.com", forKey: "summaryEmailRecipient")

        let accounts = AccountStore.all(in: directory, defaults: defaults)

        #expect(accounts.count == 1)
        #expect(accounts[0].id == "default")
        #expect(accounts[0].displayName == "Min")
        #expect(accounts[0].email == "me@example.com")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("accounts.json").path))
    }

    @Test func keychainAccountMappingKeepsDefaultLegacyRawValue() {
        #expect(KeychainStore.keychainAccount(for: .openAI, accountId: "default") == "openAI")
        #expect(KeychainStore.keychainAccount(for: .anthropic, accountId: "") == "anthropic")
        #expect(KeychainStore.keychainAccount(for: .composio, accountId: "team1234") == "team1234.composio")
    }

    @Test func accountDefaultsMapDefaultToLegacyKeyAndOthersToNamespacedKey() throws {
        let defaults = try temporaryDefaults()

        #expect(AccountDefaults.key("summaryEmailRecipient", accountId: "default") == "summaryEmailRecipient")
        #expect(AccountDefaults.key("summaryEmailRecipient", accountId: "abc123") == "acct.abc123.summaryEmailRecipient")

        defaults.set("abc123", forKey: AccountStore.currentAccountIdKey)
        AccountDefaults.set("user-1", for: "composioUserId", defaults: defaults)
        #expect(defaults.string(forKey: "acct.abc123.composioUserId") == "user-1")
        #expect(defaults.string(forKey: "composioUserId") == nil)
    }

    @Test func connectionsURLKeepsDefaultLegacyAndNamespacesOthers() throws {
        let directory = URL(fileURLWithPath: "/tmp/arca-test", isDirectory: true)

        let defaultURL = ArcaConfig.connectionsURL(accountId: "default", arcaDirectory: directory)
        let otherURL = ArcaConfig.connectionsURL(accountId: "abc123", arcaDirectory: directory)

        #expect(defaultURL.path == "/tmp/arca-test/connections.json")
        #expect(otherURL.path == "/tmp/arca-test/accounts/abc123/connections.json")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-account-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryDefaults() throws -> UserDefaults {
        let suiteName = "arca-account-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestSetupError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private enum TestSetupError: Error {
        case defaultsUnavailable
    }
}

import Foundation

public struct ArcaAccount: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var displayName: String
    public var email: String?
    public let createdAt: Date

    public init(id: String, displayName: String, email: String?, createdAt: Date) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.createdAt = createdAt
    }
}

public enum AccountStore {
    public static let defaultAccountId = "default"
    public static let currentAccountIdKey = "currentAccountId"

    public static func all() -> [ArcaAccount] {
        all(in: ArcaConfig.arcaDirectory, defaults: .standard)
    }

    public static func current() -> ArcaAccount {
        current(in: ArcaConfig.arcaDirectory, defaults: .standard)
    }

    @discardableResult
    public static func add(displayName: String, email: String?) -> ArcaAccount {
        add(displayName: displayName, email: email, in: ArcaConfig.arcaDirectory, defaults: .standard)
    }

    public static func switchTo(id: String) {
        switchTo(id: id, in: ArcaConfig.arcaDirectory, defaults: .standard)
    }

    public static func currentAccountId() -> String {
        _ = all()
        return currentAccountId(defaults: .standard)
    }

    public static func isDefault(_ id: String) -> Bool {
        id.isEmpty || id == defaultAccountId
    }

    static func all(in directory: URL, defaults: UserDefaults) -> [ArcaAccount] {
        let url = accountsURL(in: directory)
        if let data = try? Data(contentsOf: url),
           let accounts = try? JSONDecoder().decode([ArcaAccount].self, from: data),
           !accounts.isEmpty {
            return accounts
        }

        let account = defaultAccount(defaults: defaults)
        persist([account], to: url)
        return [account]
    }

    static func current(in directory: URL, defaults: UserDefaults) -> ArcaAccount {
        let accounts = all(in: directory, defaults: defaults)
        let id = currentAccountId(defaults: defaults)
        return accounts.first { $0.id == id }
            ?? accounts.first { isDefault($0.id) }
            ?? defaultAccount(defaults: defaults)
    }

    static func add(displayName: String, email: String?, in directory: URL, defaults: UserDefaults) -> ArcaAccount {
        var accounts = all(in: directory, defaults: defaults)
        let existing = Set(accounts.map(\.id))
        let account = ArcaAccount(
            id: randomSlug(excluding: existing),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Me" : displayName,
            email: cleanEmail(email),
            createdAt: .now
        )
        accounts.append(account)
        persist(accounts, to: accountsURL(in: directory))
        return account
    }

    static func switchTo(id: String, in directory: URL, defaults: UserDefaults) {
        let accounts = all(in: directory, defaults: defaults)
        guard accounts.contains(where: { $0.id == id }) else { return }
        defaults.set(id, forKey: currentAccountIdKey)
    }

    static func currentAccountId(defaults: UserDefaults) -> String {
        let id = defaults.string(forKey: currentAccountIdKey) ?? defaultAccountId
        return id.isEmpty ? defaultAccountId : id
    }

    private static func accountsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("accounts.json")
    }

    private static func defaultAccount(defaults: UserDefaults) -> ArcaAccount {
        let displayName = defaults.string(forKey: "ownerName")
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? "Me"
        return ArcaAccount(
            id: defaultAccountId,
            displayName: displayName,
            email: cleanEmail(defaults.string(forKey: "summaryEmailRecipient")),
            createdAt: .now
        )
    }

    private static func cleanEmail(_ email: String?) -> String? {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func persist(_ accounts: [ArcaAccount], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(accounts)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[ArcaVoice] account registry write failed: %@", "\(error)")
        }
    }

    private static func randomSlug(excluding existing: Set<String>) -> String {
        for _ in 0..<10 {
            let slug = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            if !existing.contains(slug) { return slug }
        }
        return "acct\(Int(Date.now.timeIntervalSince1970))"
    }
}

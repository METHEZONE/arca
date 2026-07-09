import Foundation

public enum AccountDefaults {
    public static func key(_ base: String) -> String {
        key(base, accountId: AccountStore.currentAccountId())
    }

    public static func key(_ base: String, accountId: String) -> String {
        AccountStore.isDefault(accountId) ? base : "acct.\(accountId).\(base)"
    }

    public static func string(_ base: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(base, accountId: AccountStore.currentAccountId(defaults: defaults)))
    }

    public static func set(_ value: String?, for base: String, defaults: UserDefaults = .standard) {
        let scopedKey = key(base, accountId: AccountStore.currentAccountId(defaults: defaults))
        if let value {
            defaults.set(value, forKey: scopedKey)
        } else {
            defaults.removeObject(forKey: scopedKey)
        }
    }

    public static func bool(_ base: String, defaults: UserDefaults = .standard) -> Bool? {
        let scopedKey = key(base, accountId: AccountStore.currentAccountId(defaults: defaults))
        guard defaults.object(forKey: scopedKey) != nil else { return nil }
        return defaults.bool(forKey: scopedKey)
    }

    public static func set(_ value: Bool, for base: String, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key(base, accountId: AccountStore.currentAccountId(defaults: defaults)))
    }

    public static func int(_ base: String, defaults: UserDefaults = .standard) -> Int? {
        let scopedKey = key(base, accountId: AccountStore.currentAccountId(defaults: defaults))
        guard defaults.object(forKey: scopedKey) != nil else { return nil }
        return defaults.integer(forKey: scopedKey)
    }

    public static func set(_ value: Int, for base: String, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key(base, accountId: AccountStore.currentAccountId(defaults: defaults)))
    }
}

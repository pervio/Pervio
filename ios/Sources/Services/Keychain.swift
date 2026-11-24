import Foundation
import Security

/// The three Security.framework calls `Keychain` makes, behind a seam.
///
/// Production is `SystemKeychainStore` below — the same `SecItem*` calls this
/// file always made, unchanged. It is a protocol only so the wrapper can be
/// tested at all: the unit-test host is built with `CODE_SIGNING_ALLOWED=NO`
/// (see scripts/lib/layers.sh), so it carries no keychain entitlement and every
/// real `SecItemAdd` answers `errSecMissingEntitlement` (-34018). Left as-is,
/// the file that holds every server's PRIVATE KEY had no test at all.
protocol KeychainStore {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainStore: KeychainStore {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Minimal Keychain wrapper for storing per-profile secrets (private key PEM or
/// password). Secrets are keyed by the profile UUID so they never touch
/// UserDefaults or a backup-able plist.
enum Keychain {
    private static let service = "app.pervio.secrets"

    /// The real keychain. Only a test ever assigns this (and puts it back).
    static var store: KeychainStore = SystemKeychainStore()

    /// Store (or rotate) a secret. UPDATE-first, add-fallback — never the old
    /// "delete, then add": that pair discarded both statuses, so a delete that
    /// succeeded followed by an add that failed (locked device, entitlement
    /// hiccup) silently DESTROYED the only copy of a server's private key
    /// (2026-08-22 audit). Update mutates in place — there is no window with
    /// zero copies — and every status is checked. Returns false when nothing
    /// was stored; callers surface that instead of sailing on.
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // WhenUnlockedThisDeviceOnly: readable ONLY while the device is unlocked
        // (not after-first-unlock-while-locked), and never leaves this device —
        // excluded from iCloud/iTunes backups, not restorable onto another phone.
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let upd = store.update(base, attrs)
        if upd == errSecSuccess { return true }
        guard upd == errSecItemNotFound else { return false }
        var add = base
        for (k, v) in attrs { add[k] = v }
        return store.add(add) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let (status, item) = store.copyMatching(query)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        _ = store.delete(query)
    }
}

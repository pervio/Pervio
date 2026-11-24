import XCTest
import Security
@testable import Pervio

/// A stand-in for Security.framework that follows the rules Apple documents for
/// generic passwords — the ones this wrapper's correctness depends on:
///
///  * `SecItemAdd` for an account that ALREADY has an item answers
///    `errSecDuplicateItem` and changes nothing (this is the rule that makes
///    "delete, then add" load-bearing rather than decorative),
///  * `SecItemCopyMatching` / `SecItemDelete` answer `errSecItemNotFound` when
///    nothing matches,
///  * matching is on (class, service, account) together.
///
/// It exists because the unit-test host is unsigned (`CODE_SIGNING_ALLOWED=NO`),
/// so on the simulator every real `SecItemAdd` answers -34018
/// (errSecMissingEntitlement) — measured, not assumed. Using the real keychain
/// here would test nothing and leave a false green behind.
final class FakeKeychainStore: KeychainStore {
    private struct Row { var klass: String; var service: String; var account: String
                         var attrs: [String: Any] }
    private var rows: [Row] = []

    /// Every call, in order, as "verb account" — so a test can assert that `set`
    /// really deletes BEFORE it adds.
    private(set) var calls: [String] = []
    /// When set, every call fails with this status (a locked device, a missing
    /// entitlement, a keychain that simply won't answer).
    var forcedStatus: OSStatus?

    private func key(_ q: [String: Any]) -> (String, String, String) {
        ((q[kSecClass as String] as? String) ?? "",
         (q[kSecAttrService as String] as? String) ?? "",
         (q[kSecAttrAccount as String] as? String) ?? "")
    }
    private func matches(_ q: [String: Any]) -> [Int] {
        let (k, s, a) = key(q)
        return rows.indices.filter { rows[$0].klass == k && rows[$0].service == s
                                                        && rows[$0].account == a }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        calls.append("add \(key(attributes).2)")
        if let forcedStatus { return forcedStatus }
        guard matches(attributes).isEmpty else { return errSecDuplicateItem }
        let (k, s, a) = key(attributes)
        rows.append(Row(klass: k, service: s, account: a, attrs: attributes))
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        calls.append("copy \(key(query).2)")
        if let forcedStatus { return (forcedStatus, nil) }
        let found = matches(query)
        guard !found.isEmpty else { return (errSecItemNotFound, nil) }
        let all = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
        if query[kSecReturnData as String] as? Bool == true {
            let data = rows[found[0]].attrs[kSecValueData as String] as? Data
            return (errSecSuccess, data as AnyObject?)
        }
        if all {
            return (errSecSuccess, found.map { rows[$0].attrs } as AnyObject)
        }
        return (errSecSuccess, rows[found[0]].attrs as AnyObject)
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        calls.append("update \(key(query).2)")
        if let forcedStatus { return forcedStatus }
        let found = matches(query)
        guard !found.isEmpty else { return errSecItemNotFound }
        for i in found {
            for (k, v) in attributes { rows[i].attrs[k] = v }
        }
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        calls.append("delete \(key(query).2)")
        if let forcedStatus { return forcedStatus }
        let found = matches(query)
        guard !found.isEmpty else { return errSecItemNotFound }
        for i in found.reversed() { rows.remove(at: i) }
        return errSecSuccess
    }

    /// What the store actually holds for one account (attributes as handed to it).
    func stored(_ account: String) -> [String: Any]? {
        rows.first { $0.account == account }?.attrs
    }
    func count(_ account: String) -> Int { rows.filter { $0.account == account }.count }
}

/// B3: `Keychain` holds the SSH PRIVATE KEY of every server the user has added,
/// and it had no tests. All three of its methods discard the OSStatus they get
/// back, so every way they can fail, they fail silently:
///
///  * an overwrite that doesn't overwrite leaves the OLD key in place — the user
///    pastes a rotated key, the app keeps using the dead one, and nothing says so;
///  * an item stored under a weaker accessibility class rides into iCloud/iTunes
///    backups and restores onto another phone — a private key leaving the device
///    it was meant to be locked to, with every functional test still green.
///
/// What is checked here is the wrapper: the exact attributes it hands to
/// Security.framework and how it behaves when the OS answers. Security.framework's
/// own behaviour is assumed, and the fake above encodes the documented parts of it.
final class KeychainTests: XCTestCase {

    private var fake = FakeKeychainStore()
    private var realStore: KeychainStore!

    override func setUp() {
        super.setUp()
        realStore = Keychain.store
        fake = FakeKeychainStore()
        Keychain.store = fake
    }
    override func tearDown() {
        Keychain.store = realStore     // never leave the app pointed at a fake
        super.tearDown()
    }

    /// A private key is not a short ASCII token: it has line breaks and a
    /// trailing newline that matters, and the passphrase next to it may be
    /// non-ASCII. Round-tripping it byte for byte is the whole job.
    func testB3_aPrivateKeyPEMComesBackExactlyAsItWentIn() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gt
        ZWQyNTUxOQAAACDq7+/vAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
        -----END OPENSSH PRIVATE KEY-----

        """
        Keychain.set(pem, for: "profile-1")

        XCTAssertEqual(Keychain.get("profile-1"), pem,
                       "the stored private key did not come back identical — a key that loses "
                       + "its trailing newline or a line break will not authenticate")
        XCTAssertEqual(fake.stored("profile-1")?[kSecValueData as String] as? Data, Data(pem.utf8),
                       "what reached the keychain was not the UTF-8 of the key")

        Keychain.set("密码 with spaces 🔑", for: "profile-2")
        XCTAssertEqual(Keychain.get("profile-2"), "密码 with spaces 🔑",
                       "a non-ASCII secret was mangled")
    }

    /// Replacing a server's key is the ordinary case (rotated key, fixed typo).
    /// UPDATE-first since 2026-08-22: the old "delete, then add" pair had a
    /// window with ZERO copies — a delete that succeeded followed by an add
    /// that failed silently destroyed the only copy of the key. Update mutates
    /// in place; add only ever runs for a brand-new item.
    func testB3_storingASecondSecretUnderTheSameKeyReplacesTheFirst() {
        Keychain.set("old-key-material", for: "profile-1")
        Keychain.set("new-key-material", for: "profile-1")

        XCTAssertEqual(Keychain.get("profile-1"), "new-key-material",
                       "the replacement was dropped and the OLD secret is still what the app "
                       + "will connect with")
        XCTAssertEqual(fake.count("profile-1"), 1,
                       "the overwrite left duplicate items — which one the OS hands back is "
                       + "then anyone's guess")
        XCTAssertEqual(fake.calls, ["update profile-1", "add profile-1",
                                    "update profile-1",
                                    "copy profile-1"],
                       "a rotation must UPDATE in place (no zero-copy window) and only fall "
                       + "back to add for a brand-new item: \(fake.calls)")
    }

    /// The failure that motivated the rewrite: the OS refuses the write. The old
    /// code had already deleted the only copy by then and told nobody; now the
    /// key survives untouched and the caller is told the write failed.
    func testB3_aRefusedWriteLeavesTheOldSecretIntactAndReturnsFalse() {
        Keychain.set("the-only-copy", for: "profile-1")
        fake.forcedStatus = errSecInteractionNotAllowed      // e.g. device locked
        let ok = Keychain.set("rotated", for: "profile-1")
        fake.forcedStatus = nil

        XCTAssertFalse(ok, "a refused write must report failure, not sail on")
        XCTAssertEqual(Keychain.get("profile-1"), "the-only-copy",
                       "the refused rotation must leave the existing key untouched — "
                       + "the old delete-then-add destroyed it here")
    }

    /// Deleting a server must take its secret with it: a private key left behind
    /// outlives the account it belonged to.
    func testB3_deleteRemovesTheSecretAndUnknownKeysReadAsNil() {
        Keychain.set("secret-to-remove", for: "profile-1")
        XCTAssertEqual(Keychain.get("profile-1"), "secret-to-remove", "precondition: stored")

        Keychain.delete("profile-1")

        XCTAssertNil(Keychain.get("profile-1"), "the deleted secret is still readable")
        XCTAssertEqual(fake.count("profile-1"), 0, "the item is still in the keychain")
        XCTAssertNil(Keychain.get("never-stored"),
                     "reading a key that was never stored must answer nil")

        Keychain.set("still-here", for: "profile-1")
        Keychain.delete("never-stored")          // must not disturb anything else
        XCTAssertEqual(Keychain.get("profile-1"), "still-here",
                       "deleting an unknown key removed an unrelated secret")
    }

    /// Two servers, two secrets: reading one must never answer with the other's.
    func testB3_secretsAreIsolatedPerProfileKey() {
        Keychain.set("key-for-A", for: "profile-A")
        Keychain.set("key-for-B", for: "profile-B")

        XCTAssertEqual(Keychain.get("profile-A"), "key-for-A")
        XCTAssertEqual(Keychain.get("profile-B"), "key-for-B")

        Keychain.delete("profile-A")
        XCTAssertNil(Keychain.get("profile-A"))
        XCTAssertEqual(Keychain.get("profile-B"), "key-for-B",
                       "deleting one server's secret took another server's with it")
    }

    /// The security property the file promises, checked on the attributes that
    /// actually reach the OS. `WhenUnlockedThisDeviceOnly` is what keeps the
    /// private key out of device backups and off any other phone; every other
    /// accessibility class (and `Synchronizable`) breaks that promise without
    /// breaking a single functional test.
    func testB3_theStoredItemIsDeviceOnlyAndNotBackedUp() {
        Keychain.set("-----BEGIN OPENSSH PRIVATE KEY-----", for: "profile-1")

        guard let attrs = fake.stored("profile-1") else {
            return XCTFail("nothing was stored at all")
        }
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                       "the private key is stored under a weaker accessibility class than "
                       + "WhenUnlockedThisDeviceOnly — it can then ride into an iCloud/iTunes "
                       + "backup and be restored onto a different phone")
        XCTAssertNotEqual(attrs[kSecAttrSynchronizable as String] as? Bool, true,
                          "the private key is marked synchronizable — it would be pushed to "
                          + "iCloud Keychain")
        XCTAssertEqual(attrs[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attrs[kSecAttrService as String] as? String, "app.pervio.secrets",
                       "the service name is what scopes these items to this app's own store")
    }

    /// The read path when the OS refuses: a locked device, a missing entitlement,
    /// a keychain that is simply unavailable. `get` must answer nil — not crash,
    /// and not hand back a stale or empty string that would be tried as a key.
    func testB3_aKeychainThatRefusesToAnswerReadsAsNoSecret() {
        Keychain.set("real-secret", for: "profile-1")
        fake.forcedStatus = errSecInteractionNotAllowed

        XCTAssertNil(Keychain.get("profile-1"),
                     "a keychain that refused to answer was read as a secret")

        fake.forcedStatus = OSStatus(-34018)      // errSecMissingEntitlement
        XCTAssertNil(Keychain.get("profile-1"))
        Keychain.set("another", for: "profile-2")  // must not trap on a failing store
        Keychain.delete("profile-2")

        fake.forcedStatus = nil
        XCTAssertEqual(Keychain.get("profile-1"), "real-secret",
                       "the secret must still be there once the keychain answers again")
    }
}

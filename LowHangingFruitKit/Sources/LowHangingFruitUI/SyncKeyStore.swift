import CryptoKit
import Foundation
import LowHangingFruitKit
import Security

/// The end-to-end key `K` from the pairing QR, kept in the Keychain.
///
/// Same pattern and the same reasons as `SessionCookieStore`: `K` decrypts the
/// student's synced completions and manual tasks, so it is a credential, not a
/// preference. It does NOT go in `UserDefaults.lhf` (unencrypted, in backups,
/// shared with the widget) and it is never synced: the accessibility class is
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it stays out of
/// iCloud Keychain and out of a restore onto another phone. A restored phone
/// then simply has to pair again, which costs one QR scan; a key that followed
/// a backup would cost the promise that only the student's own devices can read
/// the blobs. After first unlock, not "when unlocked", so a background sync can
/// still read it.
///
/// Only the app process ever needs it. The widget reads the snapshot the app
/// writes and never touches sync, so no access group is set and nothing here is
/// reachable from the extension.
///
/// One item, the raw 32 bytes. A stored value of any other length is treated as
/// absent rather than trusted (`key(from:)`), because `SymmetricKey` will wrap
/// any byte count and the failure would then surface as an undecryptable blob
/// on the other device.
enum SyncKeyStore {
    private static let service = "com.lhf.lowhangingfruit.sync.pairingKey"
    private static let account = "pairingKey"

    /// Stores `key`, replacing any earlier one (a re-pair). False if the
    /// Keychain refused; the caller must then not tell the student they are
    /// paired. Update in place, add only when nothing is there
    /// (`KeychainItem.write`), so a refused re-pair leaves the old key
    /// rather than none.
    @discardableResult
    static func save(_ key: SymmetricKey) -> Bool {
        // Never touch the developer's real Keychain item under `swift test`;
        // the same guard `SessionCookieStore.merge` has, for the same reason.
        guard !SharedDefaults.isTestRunner else { return false }
        let data = key.withUnsafeBytes { Data($0) }
        guard data.count == keyByteCount else { return false }
        return KeychainItem.write(data, base: baseQuery()) == errSecSuccess
    }

    /// The stored key in three answers (see `KeychainRead`). A value of the
    /// wrong length reads as not found (`key(from:)`).
    static func read() -> KeychainRead<SymmetricKey> {
        KeychainItem.read(baseQuery()).decoded { key(from: $0) }
    }

    static func load() -> SymmetricKey? {
        read().value
    }

    /// Forgets the key: unpairing, or disconnecting Canvas.
    static func delete() {
        guard !SharedDefaults.isTestRunner else { return }
        KeychainItem.delete(baseQuery())
    }

    static let keyByteCount = 32

    /// Pure half of `load()`, so the length rule is testable without a Keychain.
    static func key(from data: Data) -> SymmetricKey? {
        data.count == keyByteCount ? SymmetricKey(data: data) : nil
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

import CryptoKit
import Foundation

/// The envelope around a sync snapshot: AES-256-GCM, a fresh random 12-byte
/// nonce per write, no associated data, sealed bytes `nonce || ciphertext ||
/// tag` (CryptoKit's `SealedBox.combined`), sent as standard base64. The
/// extension does the same with WebCrypto; the shared vector proves it.
///
/// The key `K` reaches the phone in the pairing QR's URL fragment (`#k=`),
/// which is base64url without padding. Anything that is not exactly 32 bytes
/// is refused here, because a short key silently "works" with some
/// primitives and the failure then shows up as an undecryptable blob on the
/// other device, far from the cause.
public enum SyncSnapshotCrypto {
    public enum CryptoError: Error, Equatable {
        case badKey
        case badEnvelope
    }

    public static func seal(_ plaintext: Data, key: SymmetricKey,
                            nonce: AES.GCM.Nonce? = nil) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        // `combined` is nil only for a non-12-byte nonce, which Nonce() never makes.
        guard let combined = box.combined else { throw CryptoError.badEnvelope }
        return combined.base64EncodedString()
    }

    public static func open(_ base64: String, key: SymmetricKey) throws -> Data {
        guard let combined = Data(base64Encoded: base64) else { throw CryptoError.badEnvelope }
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }

    /// Unpadded base64url (43 characters) of exactly 32 bytes, nothing else.
    public static func key(fromBase64URL text: String) throws -> SymmetricKey {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard text.count == 43, text.allSatisfy({ allowed.contains($0) }) else {
            throw CryptoError.badKey
        }
        let standard = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: standard), data.count == 32 else {
            throw CryptoError.badKey
        }
        return SymmetricKey(data: data)
    }

    public static func base64URL(from key: SymmetricKey) throws -> String {
        let data = key.withUnsafeBytes { Data($0) }
        guard data.count == 32 else { throw CryptoError.badKey }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

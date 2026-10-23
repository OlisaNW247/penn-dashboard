import CryptoKit
import Foundation

/// The pairing QR's payload: `smooth://pair?c=<code>#k=<key>`
/// (docs/CHROME_EXTENSION.md, "Pairing").
///
/// The code goes to the server in a `pair` claim; the key is the end-to-end
/// key `K` and must never go anywhere but the Keychain. That is why it rides
/// in the URL fragment: a fragment is not part of what a browser or a server
/// would ever be sent, so even a QR that gets opened by the wrong app leaks
/// the key to nobody but that app.
///
/// Parsing is deliberately strict and returns nil for everything else. The
/// scheme is a custom one, so any app on the phone, or any web page, can hand
/// this app a `smooth://` URL; the phone is about to ask the student "pair this
/// laptop?" on the strength of it, and a half-valid link (no key, a key of the
/// wrong length, a second `c=`) is either a bug or an attack, never something
/// to be guessed into shape. The wrong fix would be a lenient parse that takes
/// "the first c it sees": the extra parameters then mean different things to
/// the two sides.
///
/// The code's shape is checked only loosely (base64url characters, 8 to 64 of
/// them) rather than as exactly the 22 characters the server mints today, so
/// the server can lengthen it without shipping a phone build; the server is the
/// judge of whether a code is real (`404 pairing_not_found`).
public struct PairingLink {
    public let code: String
    public let key: SymmetricKey

    public init(code: String, key: SymmetricKey) {
        self.code = code
        self.key = key
    }

    public init?(url: URL) {
        self.init(text: url.absoluteString)
    }

    public init?(text: String) {
        guard let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "smooth",
              parts.host?.lowercased() == "pair",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty
        else { return nil }

        // Exactly one query item, `c`. Percent-decoding by `queryItems` is
        // fine because the character check below runs on the decoded value.
        guard let items = parts.queryItems, items.count == 1,
              items[0].name == "c", let code = items[0].value,
              Self.isPlausibleCode(code)
        else { return nil }

        // The fragment is exactly `k=<key>`, read raw (not percent-decoded):
        // a percent sign can never be part of a valid key.
        guard let fragment = parts.percentEncodedFragment, fragment.hasPrefix("k=") else { return nil }
        guard let key = try? SyncSnapshotCrypto.key(fromBase64URL: String(fragment.dropFirst(2))) else {
            return nil
        }
        self.init(code: code, key: key)
    }

    static func isPlausibleCode(_ code: String) -> Bool {
        guard (8...64).contains(code.count) else { return false }
        return code.unicodeScalars.allSatisfy { u in
            (u.value >= 0x30 && u.value <= 0x39) || (u.value >= 0x41 && u.value <= 0x5A)
                || (u.value >= 0x61 && u.value <= 0x7A) || u == "-" || u == "_"
        }
    }
}

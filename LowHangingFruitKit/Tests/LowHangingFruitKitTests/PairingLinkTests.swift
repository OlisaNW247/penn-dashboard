import CryptoKit
import Foundation
import Testing
@testable import LowHangingFruitKit

/// `smooth://pair?c=<code>#k=<key>`, the pairing QR. Strict by design: the
/// phone is about to ask the student to approve a pairing on the strength of
/// whatever `smooth://` URL reached it.
@Suite struct PairingLinkTests {
    static let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" // bytes 0...31
    static let code = "Zm9vYmFyYmF6cXV4MTIzNA"

    @Test func parsesCodeAndKey() throws {
        let link = try #require(PairingLink(text: "smooth://pair?c=\(Self.code)#k=\(Self.key)"))
        #expect(link.code == Self.code)
        #expect(try SyncSnapshotCrypto.base64URL(from: link.key) == Self.key)
        #expect(link.key.withUnsafeBytes { Data($0) } == Data(0..<32))
    }

    @Test func parsesFromURL() throws {
        let url = try #require(URL(string: "smooth://pair?c=\(Self.code)#k=\(Self.key)"))
        #expect(PairingLink(url: url)?.code == Self.code)
    }

    @Test(arguments: [
        "",
        "not a link",
        "https://pair?c=Zm9vYmFyYmF6cXV4MTIzNA#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        "smooth://other?c=Zm9vYmFyYmF6cXV4MTIzNA#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        "smooth://pair/extra?c=Zm9vYmFyYmF6cXV4MTIzNA#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        "smooth://pair:8080?c=Zm9vYmFyYmF6cXV4MTIzNA#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        "smooth://pair#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",           // no code
        "smooth://pair?c=#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",         // empty code
        "smooth://pair?c=short#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",    // too short
        "smooth://pair?c=Zm9vYmFy$mF6cXV4MTIzNA#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        "smooth://pair?c=Zm9vYmFyYmF6cXV4MTIzNA&x=1#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        "smooth://pair?c=Zm9vYmFyYmF6cXV4MTIzNA&c=Zm9vYmFyYmF6cXV4MTIzNA#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        "smooth://pair?c=Zm9vYmFyYmF6cXV4MTIzNA",                                  // no key
        "smooth://pair?c=Zm9vYmFyYmF6cXV4MTIzNA#",                                 // empty fragment
        "smooth://pair?c=Zm9vYmFyYmF6cXV4MTIzNA#k=",
        "smooth://pair?c=Zm9vYmFyYmF6cXV4MTIzNA#key=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        "smooth://pair?c=Zm9vYmFyYmF6cXV4MTIzNA#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh",   // 42 chars
        "smooth://pair?c=Zm9vYmFyYmF6cXV4MTIzNA#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=", // padded
        "smooth://pair?c=Zm9vYmFyYmF6cXV4MTIzNA#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh+",  // not url-safe
        "smooth://pair?c=Zm9vYmFyYmF6cXV4MTIzNA#k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&x=1",
    ])
    func rejects(_ text: String) {
        #expect(PairingLink(text: text) == nil)
    }
}

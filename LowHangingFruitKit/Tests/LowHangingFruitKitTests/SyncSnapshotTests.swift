import CryptoKit
import Foundation
import Testing
@testable import LowHangingFruitKit

/// The phone half of the sync snapshot contract. The vector strings below are
/// copied from chrome-extension/test/fixtures/sync-vector-1.json; the
/// extension's suite pins the same file, so never change one side alone.
@Suite struct SyncSnapshotTests {
    static let keyHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    static let nonceHex = "000102030405060708090a0b"
    static let plaintext = #"{"format":1,"deviceId":"vector-device-0001","writtenAt":"2026-10-22T12:00:00.000Z","completions":{"canvas:123":{"done":true,"at":"2026-10-22T11:00:00.000Z"}},"dueEdits":{},"manual":{},"workList":[]}"#
    static let sealed = "AAECAwQFBgcICQoLPCCwdLeIo2+ve6ank40dG+q14n2UWWVeTgKG8XIbLdZkZsefyuwiqESVXcGq8FpRmi0F4xuigeAdpRorLs7E3t0O9C7i4xxRLG6aXsG/PthiqOVAFQw+GJGY6qUXnsqv8YN7hcUvvnvtJg+Ae1cbBJgDDcWG5x/uP4oy4aCHGiyBcDL2huHmYjjMepNp6334BsTZBQU/o3q8BcoKh/7Liuby23GAi79cnRig1v3t59Xor6YAsdAOkEeor7Uaid6AZ26woVCghbSQB3JvLG+e1pe7PWunMA=="

    static func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }
    static var key: SymmetricKey { SymmetricKey(data: hex(keyHex)) }

    static func t(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: 1_792_670_400 + Double(minute) * 60) // 2026-10-22T12:00Z + minutes
    }

    static func snap(_ device: String, completions: [String: SyncSnapshot.Completion] = [:],
                     dueEdits: [String: SyncSnapshot.DueEdit] = [:],
                     manual: [String: SyncSnapshot.ManualTask] = [:],
                     workList: [SyncSnapshot.WorkItem] = []) -> SyncSnapshot {
        SyncSnapshot(deviceId: device, writtenAt: t(0), completions: completions,
                     dueEdits: dueEdits, manual: manual, workList: workList)
    }

    static func task(removed: Bool, title: String = "x", at: Int) -> SyncSnapshot.ManualTask {
        .init(title: title, course: "C", dueAt: nil, kind: .assignment, repeatsWeekly: false,
              removed: removed, at: t(at))
    }

    // MARK: vector

    @Test func sealWithFixedNonceMatchesVector() throws {
        let nonce = try AES.GCM.Nonce(data: Self.hex(Self.nonceHex))
        let out = try SyncSnapshotCrypto.seal(Data(Self.plaintext.utf8), key: Self.key, nonce: nonce)
        #expect(out == Self.sealed)
    }

    @Test func openReturnsVectorPlaintext() throws {
        let out = try SyncSnapshotCrypto.open(Self.sealed, key: Self.key)
        #expect(String(decoding: out, as: UTF8.self) == Self.plaintext)
    }

    @Test func decodeThenEncodeReproducesVectorBytes() throws {
        let snapshot = try SyncSnapshot.decode(Data(Self.plaintext.utf8))
        #expect(snapshot.deviceId == "vector-device-0001")
        #expect(snapshot.completions["canvas:123"]?.done == true)
        #expect(String(decoding: snapshot.canonicalJSON(), as: UTF8.self) == Self.plaintext)
    }

    @Test func canonicalJSONFieldOrderNullsAndSortedKeys() {
        let s = Self.snap("d",
            completions: ["b": .init(done: false, at: Self.t(0)), "a": .init(done: true, at: Self.t(1))],
            dueEdits: ["k": .init(dueAt: nil, at: Self.t(0))],
            manual: ["m": .init(title: "a/\"b\"\n", course: "C", dueAt: nil, kind: .assignment,
                                repeatsWeekly: true, removed: false, at: Self.t(0))],
            workList: [.init(id: "i", course: "C", title: "T", dueAt: Self.t(2), kind: .quiz,
                             source: "s", url: nil, done: false)])
        let text = String(decoding: s.canonicalJSON(), as: UTF8.self)
        #expect(text == #"{"format":1,"deviceId":"d","writtenAt":"2026-10-22T12:00:00.000Z","completions":{"a":{"done":true,"at":"2026-10-22T12:01:00.000Z"},"b":{"done":false,"at":"2026-10-22T12:00:00.000Z"}},"dueEdits":{"k":{"dueAt":null,"at":"2026-10-22T12:00:00.000Z"}},"manual":{"m":{"title":"a/\"b\"\n","course":"C","dueAt":null,"kind":"assignment","repeatsWeekly":true,"removed":false,"at":"2026-10-22T12:00:00.000Z"}},"workList":[{"id":"i","course":"C","title":"T","dueAt":"2026-10-22T12:02:00.000Z","kind":"quiz","source":"s","url":null,"done":false}]}"#)
        // And it reads back to the same value.
        #expect((try? SyncSnapshot.decode(s.canonicalJSON())) == s)
    }

    @Test func decodeIgnoresUnknownKeys() throws {
        let json = Self.plaintext.replacingOccurrences(of: #""format":1,"#, with: #""format":1,"future":{"x":1},"#)
        #expect((try SyncSnapshot.decode(Data(json.utf8))).deviceId == "vector-device-0001")
    }

    @Test func unknownKindReadsAsOther() throws {
        let s = Self.snap("d", manual: ["m": Self.task(removed: false, at: 0)])
        let json = String(decoding: s.canonicalJSON(), as: UTF8.self)
            .replacingOccurrences(of: #""kind":"assignment""#, with: #""kind":"hologram""#)
        #expect(try SyncSnapshot.decode(Data(json.utf8)).manual["m"]?.kind == .other)
    }

    @Test func decodeRejectsFormat2() {
        let json = Self.plaintext.replacingOccurrences(of: #""format":1"#, with: #""format":2"#)
        #expect(throws: DecodingError.self) { try SyncSnapshot.decode(Data(json.utf8)) }
    }

    // MARK: crypto

    @Test func tamperedEnvelopeFailsToOpen() throws {
        var bytes = Data(base64Encoded: Self.sealed)!
        bytes[20] ^= 0x01
        #expect(throws: (any Error).self) {
            try SyncSnapshotCrypto.open(bytes.base64EncodedString(), key: Self.key)
        }
        #expect(throws: (any Error).self) {
            try SyncSnapshotCrypto.open(Self.sealed, key: SymmetricKey(size: .bits256))
        }
    }

    @Test func keyBase64URLRoundTripAndRejection() throws {
        let text = try SyncSnapshotCrypto.base64URL(from: Self.key)
        #expect(text.count == 43)
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
        let back = try SyncSnapshotCrypto.key(fromBase64URL: text)
        #expect(back.withUnsafeBytes { Data($0) } == Self.hex(Self.keyHex))
        for bad in ["", "AAAA", text + "A", text + "=", String(text.dropLast()) + "+"] {
            #expect(throws: SyncSnapshotCrypto.CryptoError.self) {
                try SyncSnapshotCrypto.key(fromBase64URL: bad)
            }
        }
    }

    // MARK: merge

    @Test func newerCompletionWins() {
        let a = Self.snap("a", completions: ["k": .init(done: true, at: Self.t(1))])
        let b = Self.snap("b", completions: ["k": .init(done: false, at: Self.t(2))])
        #expect(SyncSnapshotMerge.merge(local: a, remotes: [b]).snapshot.completions["k"]?.done == false)
        #expect(SyncSnapshotMerge.merge(local: b, remotes: [a]).snapshot.completions["k"]?.done == false)
    }

    @Test func tieGoesToLargerDeviceId() {
        let a = Self.snap("a", completions: ["k": .init(done: true, at: Self.t(1))])
        let b = Self.snap("b", completions: ["k": .init(done: false, at: Self.t(1))])
        #expect(SyncSnapshotMerge.merge(local: a, remotes: [b]).snapshot.completions["k"]?.done == false)
        #expect(SyncSnapshotMerge.merge(local: b, remotes: [a]).snapshot.completions["k"]?.done == false)
    }

    @Test func tieBreakComparesUnicodeScalars() {
        // U+FF5E sorts after U+1F600 by UTF-16 units but before it by scalar.
        let low = "\u{FF5E}", high = "\u{1F600}"
        let a = Self.snap(low, completions: ["k": .init(done: true, at: Self.t(1))])
        let b = Self.snap(high, completions: ["k": .init(done: false, at: Self.t(1))])
        #expect(SyncSnapshotMerge.merge(local: a, remotes: [b]).snapshot.completions["k"]?.done == false)
    }

    @Test func untickBeatsOlderTick() {
        let ticked = Self.snap("a", completions: ["k": .init(done: true, at: Self.t(1))])
        let unticked = Self.snap("b", completions: ["k": .init(done: false, at: Self.t(5))])
        let r = SyncSnapshotMerge.merge(local: ticked, remotes: [unticked])
        #expect(r.snapshot.completions["k"] == .init(done: false, at: Self.t(5)))
    }

    @Test func tombstoneAndEditJudgedByTimeBothWays() {
        let removed = Self.snap("a", manual: ["m": Self.task(removed: true, at: 5)])
        let edited = Self.snap("b", manual: ["m": Self.task(removed: false, title: "new", at: 3)])
        #expect(SyncSnapshotMerge.merge(local: edited, remotes: [removed]).snapshot.manual["m"]?.removed == true)
        let editedLater = Self.snap("b", manual: ["m": Self.task(removed: false, title: "new", at: 9)])
        let r = SyncSnapshotMerge.merge(local: removed, remotes: [editedLater])
        #expect(r.snapshot.manual["m"]?.removed == false)
        #expect(r.snapshot.manual["m"]?.title == "new")
    }

    @Test func nullDueEditIsKeptAndWins() {
        let a = Self.snap("a", dueEdits: ["k": .init(dueAt: Self.t(30), at: Self.t(1))])
        let b = Self.snap("b", dueEdits: ["k": .init(dueAt: nil, at: Self.t(2))])
        let r = SyncSnapshotMerge.merge(local: a, remotes: [b])
        #expect(r.snapshot.dueEdits["k"] == .init(dueAt: nil, at: Self.t(2)))
    }

    @Test func threeWayMergeIsOrderIndependent() {
        let a = Self.snap("a", completions: ["k": .init(done: true, at: Self.t(1)), "j": .init(done: true, at: Self.t(4))],
                          manual: ["m": Self.task(removed: false, at: 2)])
        let b = Self.snap("b", completions: ["k": .init(done: false, at: Self.t(3)), "j": .init(done: false, at: Self.t(4))],
                          manual: ["m": Self.task(removed: true, at: 2)])
        let c = Self.snap("c", completions: ["k": .init(done: true, at: Self.t(3))],
                          dueEdits: ["d": .init(dueAt: nil, at: Self.t(1))])
        let all = [a, b, c]
        let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let results = perms.map { p in
            SyncSnapshotMerge.merge(local: all[p[0]], remotes: [all[p[1]], all[p[2]]])
        }
        for r in results {
            #expect(r.snapshot.completions == results[0].snapshot.completions)
            #expect(r.snapshot.dueEdits == results[0].snapshot.dueEdits)
            #expect(r.snapshot.manual == results[0].snapshot.manual)
        }
        #expect(results[0].snapshot.completions["k"]?.done == true)  // t3 tie: c > b
        #expect(results[0].snapshot.completions["j"]?.done == false) // t4 tie: b > a
        #expect(results[0].snapshot.manual["m"]?.removed == true)    // t2 tie: b > a
    }

    @Test func workListsStaySeparatePerRemoteDevice() {
        let item = SyncSnapshot.WorkItem(id: "i", course: "C", title: "T", dueAt: nil, kind: .quiz,
                                         source: "s", url: nil, done: false)
        let r = SyncSnapshotMerge.merge(local: Self.snap("a", workList: [item]),
                                        remotes: [Self.snap("b", workList: [item]), Self.snap("c")])
        #expect(r.snapshot.deviceId == "a")
        #expect(r.snapshot.workList == [item])
        #expect(r.remoteWorkLists.map(\.deviceId) == ["b", "c"])
        #expect(r.remoteWorkLists[0].workList == [item])
        #expect(r.remoteWorkLists[1].workList == [])
    }
}

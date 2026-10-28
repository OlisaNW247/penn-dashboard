import Foundation
import Security
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// Safe Keychain writes and three-answer reads (hardening plan A5, 2026-10-27).
//
// Every store used to "upsert" by SecItemDelete then SecItemAdd with neither
// status checked, and answered a read with "a value or nil", where nil meant
// both "not there" and "would not say". These suites drive `KeychainItem`
// through its seams (the SecItem call is a closure), so the order of calls and
// the status each returns are chosen by the test and no Keychain is touched.
// The real-Keychain round trips live in the existing serialized suites
// (`SessionCookieStoreTests`, `CanvasAccessTokenStoreTests`), which own those
// process-wide items.

nonisolated(unsafe) private let base: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.lhf.test.keychainItem",
    kSecAttrAccount as String: "account",
]

/// Records the calls `KeychainItem.write` makes, in order, and answers each
/// with the next scripted status.
private final class WriteScript {
    enum Call: Equatable { case update, add }
    var calls: [Call] = []
    var updateQueries: [NSDictionary] = []
    var updateAttributes: [NSDictionary] = []
    var addQueries: [NSDictionary] = []
    private var updateStatuses: [OSStatus]
    private var addStatuses: [OSStatus]

    init(update: [OSStatus], add: [OSStatus] = []) {
        updateStatuses = update
        addStatuses = add
    }

    func write(_ data: Data, log: KeychainStatusLog) -> OSStatus {
        KeychainItem.write(
            data,
            base: base,
            update: { query, attributes in
                self.calls.append(.update)
                self.updateQueries.append(query as NSDictionary)
                self.updateAttributes.append(attributes as NSDictionary)
                return self.updateStatuses.isEmpty ? errSecSuccess : self.updateStatuses.removeFirst()
            },
            add: { query in
                self.calls.append(.add)
                self.addQueries.append(query as NSDictionary)
                return self.addStatuses.isEmpty ? errSecSuccess : self.addStatuses.removeFirst()
            },
            log: log
        )
    }
}

@Suite("Keychain write order")
struct KeychainWriteOrderTests {
    private let payload = Data("secret".utf8)

    @Test("an existing item is updated in place: one update, no add")
    func updatesInPlace() {
        let script = WriteScript(update: [errSecSuccess])
        let status = script.write(payload, log: KeychainStatusLog())
        #expect(status == errSecSuccess)
        #expect(script.calls == [.update])
    }

    @Test("an add happens only when the update said the item is not there")
    func addsOnlyOnNotFound() {
        let script = WriteScript(update: [errSecItemNotFound], add: [errSecSuccess])
        let status = script.write(payload, log: KeychainStatusLog())
        #expect(status == errSecSuccess)
        #expect(script.calls == [.update, .add])
    }

    @Test("a refused update (locked device) never falls through to an add, so the old item stays",
          arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecIO])
    func refusedUpdateIsFinal(status refused: OSStatus) {
        let script = WriteScript(update: [refused])
        let status = script.write(payload, log: KeychainStatusLog())
        #expect(status == refused)
        #expect(script.calls == [.update])
    }

    @Test("a refused add is reported, not swallowed")
    func refusedAddIsReported() {
        let script = WriteScript(update: [errSecItemNotFound], add: [errSecInteractionNotAllowed])
        let status = script.write(payload, log: KeychainStatusLog())
        #expect(status == errSecInteractionNotAllowed)
        #expect(script.calls == [.update, .add])
    }

    @Test("a duplicate-item answer from the add (another writer won the race) is retried as an update")
    func duplicateAddRetriesAsUpdate() {
        let script = WriteScript(update: [errSecItemNotFound, errSecSuccess], add: [errSecDuplicateItem])
        let status = script.write(payload, log: KeychainStatusLog())
        #expect(status == errSecSuccess)
        #expect(script.calls == [.update, .add, .update])
    }

    @Test("the update targets the bare item and carries the data and the this-device-only accessibility")
    func updateShapes() throws {
        let script = WriteScript(update: [errSecSuccess])
        _ = script.write(payload, log: KeychainStatusLog())

        let query = try #require(script.updateQueries.first)
        #expect(query[kSecAttrService as String] as? String == "com.lhf.test.keychainItem")
        #expect(query[kSecValueData as String] == nil, "the match query never carries the new value")

        let attributes = try #require(script.updateAttributes.first)
        #expect(attributes[kSecValueData as String] as? Data == payload)
        #expect(attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test("the add carries the base item, the data and the this-device-only accessibility")
    func addShapes() throws {
        let script = WriteScript(update: [errSecItemNotFound], add: [errSecSuccess])
        _ = script.write(payload, log: KeychainStatusLog())

        let query = try #require(script.addQueries.first)
        #expect(query[kSecAttrService as String] as? String == "com.lhf.test.keychainItem")
        #expect(query[kSecAttrAccount as String] as? String == "account")
        #expect(query[kSecValueData as String] as? Data == payload)
        #expect(query[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test("every status is counted: a not-found update is an answer, a refused write is a failure")
    func statusesAreCounted() {
        let log = KeychainStatusLog()
        _ = WriteScript(update: [errSecItemNotFound], add: [errSecSuccess]).write(payload, log: log)
        #expect(log.failureCount == 0, "update-not-found then a good add is the normal first write")
        #expect(log.snapshot["update \(errSecItemNotFound)"] == 1)
        #expect(log.snapshot["add \(errSecSuccess)"] == 1)

        _ = WriteScript(update: [errSecInteractionNotAllowed]).write(payload, log: log)
        #expect(log.failureCount == 1)
        #expect(log.lastFailure == errSecInteractionNotAllowed)

        _ = WriteScript(update: [errSecItemNotFound], add: [errSecAuthFailed]).write(payload, log: log)
        #expect(log.failureCount == 2)
        #expect(log.lastFailure == errSecAuthFailed)
        #expect(log.summary.hasPrefix("failures 2"))
    }

    @Test("a delete counts its status too, and not-found is not a failure")
    func deleteIsCounted() {
        let log = KeychainStatusLog()
        #expect(KeychainItem.delete(base, deleteItem: { _ in errSecItemNotFound }, log: log) == errSecItemNotFound)
        #expect(log.failureCount == 0)
        #expect(KeychainItem.delete(base, deleteItem: { _ in errSecInteractionNotAllowed }, log: log)
                == errSecInteractionNotAllowed)
        #expect(log.failureCount == 1)
    }

    @Test("reset clears the counters")
    func resetClears() {
        let log = KeychainStatusLog()
        log.record(.add, errSecAuthFailed)
        log.reset()
        #expect(log.failureCount == 0)
        #expect(log.lastFailure == nil)
        #expect(log.snapshot.isEmpty)
    }
}

@Suite("Keychain reads have three answers")
struct KeychainReadAnswerTests {
    private let payload = Data("secret".utf8)

    @Test("success with data is found")
    func found() {
        #expect(KeychainItem.classify(status: errSecSuccess, data: payload) == .found(payload))
    }

    @Test("item-not-found is not found, and only that")
    func notFound() {
        #expect(KeychainItem.classify(status: errSecItemNotFound, data: nil) == .notFound)
    }

    @Test("every other status is unavailable and carries its OSStatus",
          arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecIO, errSecDecode])
    func unavailable(status: OSStatus) {
        #expect(KeychainItem.classify(status: status, data: nil) == .unavailable(status))
    }

    @Test("a success that returned no data is a strange answer, not a found")
    func successWithoutData() {
        #expect(KeychainItem.classify(status: errSecSuccess, data: nil) == .unavailable(errSecDecode))
    }

    @Test("read drives the injected call, shapes the query for one value, and counts the status")
    func readThroughSeam() {
        let log = KeychainStatusLog()
        var seen: NSDictionary?
        let result = KeychainItem.read(base, copy: { query, out in
            seen = query as NSDictionary
            out?.pointee = Data("v".utf8) as CFData
            return errSecSuccess
        }, log: log)
        #expect(result == .found(Data("v".utf8)))
        #expect(seen?[kSecReturnData as String] as? Bool == true)
        #expect(seen?[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(log.snapshot["read \(errSecSuccess)"] == 1)

        let refused = KeychainItem.read(base, copy: { _, _ in errSecInteractionNotAllowed }, log: log)
        #expect(refused == .unavailable(errSecInteractionNotAllowed))
        #expect(log.failureCount == 1)
    }

    @Test("decoded keeps unavailable and not-found as they are, and reads a payload that does not decode as not found")
    func decoded() {
        let found: KeychainRead<Data> = .found(Data("42".utf8))
        #expect(found.decoded { String(data: $0, encoding: .utf8).flatMap(Int.init) } == .found(42))
        #expect(found.decoded { _ -> Int? in nil } == .notFound)
        #expect(KeychainRead<Data>.notFound.decoded { _ -> Int? in 1 } == .notFound)
        #expect(KeychainRead<Data>.unavailable(errSecAuthFailed).decoded { _ -> Int? in 1 } == .unavailable(errSecAuthFailed))
    }

    @Test("value is the found payload and nothing else")
    func value() {
        #expect(KeychainRead<Int>.found(1).value == 1)
        #expect(KeychainRead<Int>.notFound.value == nil)
        #expect(KeychainRead<Int>.unavailable(errSecIO).value == nil)
    }
}

// MARK: - One helper for every store

@Suite("Every Keychain call goes through KeychainItem")
struct KeychainSingleDoorTests {
    /// Scans the app's sources, in the style of `ReconnectCoverTests`. A new
    /// store that reached for `SecItemDelete` or `SecItemAdd` itself would
    /// bring the delete-then-add window and the discarded statuses back.
    @Test("no store outside KeychainItem deletes, copies or adds on its own")
    func noDirectSecItemCalls() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return }

        var scanned = 0
        var offenders: [String] = []
        var pennKeyLines: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let name = file.lastPathComponent
            if name == "KeychainItem.swift" { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .filter { $0.contains("SecItem") }
            if name == "PennKeyCredentialStore.swift" {
                pennKeyLines = lines
            } else if !lines.isEmpty {
                offenders.append(name)
            }
        }
        guard scanned > 0 else { return }
        #expect(offenders.isEmpty, "SecItem* called outside KeychainItem in: \(offenders)")
        // The one allowed exception keeps its injectable signature: the two
        // default arguments `PennKeyCredentialWriteTests` replace.
        #expect(pennKeyLines.count == 2)
        #expect(pennKeyLines.allSatisfy { $0.contains("SecItemUpdate") || $0.contains("SecItemAdd") })
    }
}

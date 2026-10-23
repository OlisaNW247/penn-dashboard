import Foundation
import Security
import Testing
@testable import LowHangingFruitUI

@Suite("PennKey secure write outcomes")
struct PennKeyCredentialWriteTests {
    @Test func updatesExistingCredentialWithoutDeletingIt() {
        var inserted = false
        let result = PennKeyCredentialStore.save(username: "fixture", password: "fixture", update: { _, attributes in
            let values = attributes as NSDictionary
            #expect(values[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #expect(values[kSecValueData] is Data)
            return errSecSuccess
        }, add: { _ in inserted = true; return errSecSuccess })
        #expect(result)
        #expect(!inserted)
    }

    @Test func insertsOnlyWhenItemIsMissing() {
        var inserted = false
        let result = PennKeyCredentialStore.save(username: "fixture", password: "fixture", update: { _, _ in
            errSecItemNotFound
        }, add: { _ in inserted = true; return errSecSuccess })
        #expect(result)
        #expect(inserted)
    }

    @Test func lockedKeychainIsNotReportedAsSaved() {
        var inserted = false
        let result = PennKeyCredentialStore.save(username: "fixture", password: "fixture", update: { _, _ in
            errSecInteractionNotAllowed
        }, add: { _ in inserted = true; return errSecSuccess })
        #expect(!result)
        #expect(!inserted)
    }

    @Test func failedInsertIsNotReportedAsSaved() {
        #expect(!PennKeyCredentialStore.save(username: "fixture", password: "fixture", update: { _, _ in
            errSecItemNotFound
        }, add: { _ in errSecAuthFailed }))
    }
}

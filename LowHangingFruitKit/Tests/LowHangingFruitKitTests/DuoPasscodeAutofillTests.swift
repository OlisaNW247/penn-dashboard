import Testing
@testable import LowHangingFruitUI

@Suite struct DuoPasscodeAutofillTests {
    @Test func scriptIsGuardedToDuoHosts() {
        #expect(DuoPasscodeAutofill.script.contains("duosecurity"))
        #expect(DuoPasscodeAutofill.script.contains("location.hostname"))
    }

    @Test func scriptMarksFieldsAsOneTimeCode() {
        #expect(DuoPasscodeAutofill.script.contains("one-time-code"))
    }

    @Test func scriptNeverReadsValues() {
        #expect(!DuoPasscodeAutofill.script.contains(".value"))
    }
}

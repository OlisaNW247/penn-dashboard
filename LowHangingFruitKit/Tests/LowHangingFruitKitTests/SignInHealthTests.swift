import Foundation
import Testing
@testable import LowHangingFruitUI

/// Pure coverage for `SettingsPage.healthLines`, the text behind Profile ->
/// accounts' sign-in health lines (docs/SIGNOUT_INVESTIGATION.md, fix plan
/// step 6). The lines are what separates the sign-out causes when a student
/// can only describe a banner, so the wording of each branch is pinned, and
/// so is the rule that nothing URL-shaped (a feed link is a bearer
/// credential) ever reaches the screen. Nothing here touches the Keychain or
/// `UserDefaults.lhf`.
@Suite("Sign-in health lines")
struct SignInHealthTests {
    private static let saved = "pennkey password saved \u{2014} smooth signs in for you"
    private static let notSaved = "no pennkey password saved \u{2014} you'll sign in by hand when canvas logs you out"
    private static let duoUnknown = "duo: not trusted yet \u{2014} tap yes, this is my device next time duo asks"

    @Test("password saved, duo known, renewal known: three lines")
    func everythingKnown() {
        let lines = SettingsPage.healthLines(passwordSaved: true,
                                             duoSummary: "duo: trusted until oct 30",
                                             lastRenewal: "ok · oct 9, 9:41 am")
        #expect(lines == [Self.saved,
                          "duo: trusted until oct 30",
                          "last silent sign-in: ok · oct 9, 9:41 am"])
    }

    @Test("no password, no duo summary, no renewal: two lines, both fallbacks")
    func nothingKnown() {
        let lines = SettingsPage.healthLines(passwordSaved: false, duoSummary: nil, lastRenewal: nil)
        #expect(lines == [Self.notSaved, Self.duoUnknown])
    }

    @Test("password saved but duo unknown: the duo fallback shows")
    func passwordOnly() {
        let lines = SettingsPage.healthLines(passwordSaved: true, duoSummary: nil, lastRenewal: nil)
        #expect(lines == [Self.saved, Self.duoUnknown])
    }

    @Test("no password but a renewal outcome: the renewal line is appended last")
    func renewalWithoutPassword() {
        let lines = SettingsPage.healthLines(passwordSaved: false,
                                             duoSummary: "duo: trusted until oct 30",
                                             lastRenewal: "needs duo · oct 8")
        #expect(lines == [Self.notSaved,
                          "duo: trusted until oct 30",
                          "last silent sign-in: needs duo · oct 8"])
    }

    @Test("no combination produces a line containing http")
    func neverAURL() {
        for saved in [true, false] {
            for duo in [nil, "duo: trusted until oct 30"] as [String?] {
                for renewal in [nil, "ok · oct 9"] as [String?] {
                    let lines = SettingsPage.healthLines(passwordSaved: saved, duoSummary: duo, lastRenewal: renewal)
                    #expect(lines.allSatisfy { !$0.lowercased().contains("http") })
                }
            }
        }
    }
}

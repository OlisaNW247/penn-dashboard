import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Pure coverage for `SettingsPage.healthLines` and its parts, the text behind
/// Profile -> accounts' sign-in health lines (docs/SIGNOUT_INVESTIGATION.md,
/// fix plan step 6). The lines are what separates the sign-out causes when a
/// student can only describe a banner, so the wording of each branch is
/// pinned, and so is the rule that nothing URL-shaped (a feed link is a
/// bearer credential) ever reaches the screen. Dates are rendered with a
/// fixed locale and time zone so the expectations don't depend on the test
/// machine. Nothing here touches the Keychain or `UserDefaults.lhf`.
@Suite("Sign-in health lines")
struct SignInHealthTests {
    private static let saved = "pennkey password saved \u{2014} smooth signs in for you"
    private static let savedRejected = "pennkey password saved \u{2014} penn rejected it, update it below"
    private static let savedAwaitingDuo = "pennkey password saved \u{2014} duo needs you to sign in once"
    private static let notSaved = "no pennkey password saved \u{2014} you'll sign in by hand when canvas logs you out"
    private static let duoTrusted = "duo remembers this phone \u{2014} penn asks again about every 30 days"
    private static let duoUnknown = "duo: not trusted yet \u{2014} tap yes, this is my device next time duo asks"

    private static let utc = TimeZone(identifier: "UTC")!
    private static let enUS = Locale(identifier: "en_US")
    /// 2027-01-15 08:00 UTC, fixed and arbitrary.
    private static let reference = Date(timeIntervalSince1970: 1_800_000_000)

    private func cookie(name: String, expiresDate: Date? = nil) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: "opaque",
            .domain: "api-abc123.duosecurity.com",
            .path: "/",
        ]
        if let expiresDate {
            props[.expires] = expiresDate
        }
        return HTTPCookie(properties: props)!
    }

    // MARK: password line

    @Test("password line: saved and healthy")
    func passwordSavedHealthy() {
        #expect(SettingsPage.passwordLine(saved: true, rejected: false, awaitingDuo: false) == Self.saved)
    }

    @Test("password line: saved but penn rejected it")
    func passwordSavedRejected() {
        #expect(SettingsPage.passwordLine(saved: true, rejected: true, awaitingDuo: false) == Self.savedRejected)
    }

    @Test("password line: saved while duo is awaited")
    func passwordSavedAwaitingDuo() {
        #expect(SettingsPage.passwordLine(saved: true, rejected: false, awaitingDuo: true) == Self.savedAwaitingDuo)
    }

    @Test("password line: rejected wins over awaiting duo")
    func passwordRejectedBeatsAwaitingDuo() {
        #expect(SettingsPage.passwordLine(saved: true, rejected: true, awaitingDuo: true) == Self.savedRejected)
    }

    @Test("password line: nothing saved ignores the other two states")
    func passwordNotSaved() {
        for rejected in [true, false] {
            for awaiting in [true, false] {
                #expect(SettingsPage.passwordLine(saved: false, rejected: rejected, awaitingDuo: awaiting) == Self.notSaved)
            }
        }
    }

    // MARK: duo line

    @Test("duo line: omitted before the first cookie read, even with a live cookie")
    func duoOmittedBeforeFirstRead() {
        #expect(SettingsPage.duoLine(hasRead: false, expiry: nil) == nil)
        #expect(SettingsPage.duoLine(hasRead: false, expiry: Self.reference) == nil)
    }

    @Test("duo line: read with no live cookie says not trusted yet")
    func duoReadNoExpiry() {
        #expect(SettingsPage.duoLine(hasRead: true, expiry: nil) == Self.duoUnknown)
    }

    @Test("duo line: read with a live cookie says remembered, with no date")
    func duoReadWithExpiry() throws {
        let far = Self.reference.addingTimeInterval(399 * 86_400)
        let line = try #require(SettingsPage.duoLine(hasRead: true, expiry: far))
        #expect(line == Self.duoTrusted)
        #expect(!line.contains("2027") && !line.contains("2028"))
    }

    // MARK: duoTrustExpiry

    @Test("duoTrustExpiry: no cookies is nil")
    func expiryEmpty() {
        #expect(AppState.duoTrustExpiry(cookies: [], now: Self.reference) == nil)
    }

    @Test("duoTrustExpiry: session-only cookies are nil")
    func expiryNoExpiryCookies() {
        let cookies = [cookie(name: "_duo_session"), cookie(name: "duo_csrf")]
        #expect(AppState.duoTrustExpiry(cookies: cookies, now: Self.reference) == nil)
    }

    @Test("duoTrustExpiry: the latest of two expiries wins")
    func expiryLatestOfTwo() throws {
        let sooner = Self.reference.addingTimeInterval(10 * 86_400)
        let later = Self.reference.addingTimeInterval(29 * 86_400)
        let cookies = [
            cookie(name: "trc|AAAA|BBBB", expiresDate: later),
            cookie(name: "other", expiresDate: sooner),
            cookie(name: "_duo_session"),
        ]
        let result = try #require(AppState.duoTrustExpiry(cookies: cookies, now: Self.reference))
        #expect(abs(result.timeIntervalSince(later)) < 1)
    }

    @Test("duoTrustExpiry: an expiry already in the past is ignored")
    func expiryPastIgnored() {
        let past = Self.reference.addingTimeInterval(-86_400)
        #expect(AppState.duoTrustExpiry(cookies: [cookie(name: "trc|A|B", expiresDate: past)], now: Self.reference) == nil)
    }

    // MARK: plain renewal words

    @Test("plainRenewalDescription maps every outcome kind to plain words")
    func plainWords() {
        #expect(AppState.plainRenewalDescription(kind: .renewed) == "signed in silently")
        #expect(AppState.plainRenewalDescription(kind: .needsDuo) == "stopped at duo")
        #expect(AppState.plainRenewalDescription(kind: .timedOut) == "timed out")
        #expect(AppState.plainRenewalDescription(kind: .landedOnLoginPage) == "landed on the login page")
        #expect(AppState.plainRenewalDescription(kind: .passwordRejected) == "password rejected")
        #expect(AppState.plainRenewalDescription(kind: .notAttempted) == "not attempted")
        #expect(AppState.plainRenewalDescription(kind: .abortedByLoginPane) == "stopped for a manual login")
    }

    // MARK: last sign-in line

    @Test("last sign-in line: plain words, local date and time, context")
    func renewalLineRendered() throws {
        let summary = AppState.renewalSummary(kind: .landedOnLoginPage,
                                              at: Date(timeIntervalSince1970: 1_791_551_040), // 2026-10-09 13:04 UTC
                                              context: .background,
                                              timeZone: Self.utc)
        let line = try #require(SettingsPage.lastRenewalLine(fromSummary: summary, locale: Self.enUS, timeZone: Self.utc))
        #expect(line.hasPrefix("last silent sign-in: landed on the login page, Oct 9, 2026"))
        #expect(line.contains("1:04"))
        #expect(line.hasSuffix(" (in the background)"))
        #expect(!line.contains("landedOnLoginPage"))
    }

    @Test("last sign-in line: foreground context")
    func renewalLineForeground() throws {
        let summary = AppState.renewalSummary(kind: .renewed,
                                              at: Date(timeIntervalSince1970: 1_791_551_040),
                                              context: .foreground,
                                              timeZone: Self.utc)
        let line = try #require(SettingsPage.lastRenewalLine(fromSummary: summary, locale: Self.enUS, timeZone: Self.utc))
        #expect(line.hasPrefix("last silent sign-in: signed in silently, Oct 9, 2026"))
        #expect(line.hasSuffix(" (foreground)"))
    }

    @Test("last sign-in line: omitted for no summary or an unknown outcome")
    func renewalLineOmitted() {
        #expect(SettingsPage.lastRenewalLine(fromSummary: nil, locale: Self.enUS, timeZone: Self.utc) == nil)
        #expect(SettingsPage.lastRenewalLine(fromSummary: "", locale: Self.enUS, timeZone: Self.utc) == nil)
        #expect(SettingsPage.lastRenewalLine(fromSummary: "weird \u{00B7} x \u{00B7} y", locale: Self.enUS, timeZone: Self.utc) == nil)
    }

    @Test("last sign-in line: an unreadable time or context drops that part, not the outcome")
    func renewalLineDegrades() {
        let line = SettingsPage.lastRenewalLine(fromSummary: "needsDuo \u{00B7} nonsense \u{00B7} elsewhere",
                                                locale: Self.enUS, timeZone: Self.utc)
        #expect(line == "last silent sign-in: stopped at duo")
    }

    // MARK: assembled lines

    private func lines(passwordSaved: Bool = true,
                       rejected: Bool = false,
                       awaitingDuo: Bool = false,
                       hasReadDuo: Bool = true,
                       expiry: Date? = nil,
                       renewal: String? = nil) -> [String] {
        SettingsPage.healthLines(passwordSaved: passwordSaved,
                                 passwordRejected: rejected,
                                 awaitingDuo: awaitingDuo,
                                 hasReadDuo: hasReadDuo,
                                 duoTrustExpiry: expiry,
                                 lastRenewalSummary: renewal,
                                 locale: Self.enUS,
                                 timeZone: Self.utc)
    }

    @Test("everything known: three lines in order")
    func everythingKnown() {
        let renewal = AppState.renewalSummary(kind: .renewed,
                                              at: Date(timeIntervalSince1970: 1_791_551_040),
                                              context: .foreground,
                                              timeZone: Self.utc)
        let result = lines(expiry: Self.reference, renewal: renewal)
        #expect(result.count == 3)
        #expect(result[0] == Self.saved)
        #expect(result[1] == Self.duoTrusted)
        #expect(result[2].hasPrefix("last silent sign-in: signed in silently"))
    }

    @Test("nothing known yet: only the password line")
    func beforeFirstRead() {
        #expect(lines(passwordSaved: false, hasReadDuo: false) == [Self.notSaved])
    }

    @Test("password saved but duo not trusted: the duo fallback shows")
    func passwordOnly() {
        #expect(lines() == [Self.saved, Self.duoUnknown])
    }

    @Test("rejected and awaiting-duo states reach the assembled password line")
    func statesReachAssembly() {
        #expect(lines(rejected: true).first == Self.savedRejected)
        #expect(lines(awaitingDuo: true).first == Self.savedAwaitingDuo)
    }

    @Test("no combination produces a line containing http")
    func neverAURL() {
        let renewals: [String?] = [nil, "needsDuo \u{00B7} 2026-10-09 13:04 \u{00B7} foreground"]
        for saved in [true, false] {
            for rejected in [true, false] {
                for awaiting in [true, false] {
                    for hasRead in [true, false] {
                        for expiry in [nil, Self.reference] as [Date?] {
                            for renewal in renewals {
                                let result = lines(passwordSaved: saved, rejected: rejected, awaitingDuo: awaiting,
                                                   hasReadDuo: hasRead, expiry: expiry, renewal: renewal)
                                #expect(result.allSatisfy { !$0.lowercased().contains("http") })
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Pure coverage for the school picker's "switch school?" confirmation
/// (`OnboardingView.needsSwitchConfirmation`). The dialog guards the silent
/// loss of the saved password, cookies and Duo trust that
/// `AppState.selectCanvasInstallation` causes on a school change.
@Suite("Switch school confirmation")
struct SwitchSchoolConfirmationTests {
    private static let penn = CanvasInstallation.penn
    private static let other = CanvasInstallation(id: "other-school",
                                                  name: "Other School",
                                                  baseURL: URL(string: "https://canvas.other.edu")!,
                                                  isVerified: false)

    @Test("a different school after one was chosen needs confirmation")
    func differentSchoolAfterChoosing() {
        #expect(OnboardingView.needsSwitchConfirmation(picked: Self.other, current: Self.penn, hasChosenSchool: true))
    }

    @Test("the same school never needs confirmation")
    func sameSchool() {
        #expect(!OnboardingView.needsSwitchConfirmation(picked: Self.penn, current: Self.penn, hasChosenSchool: true))
    }

    @Test("the first run (no school chosen yet) is untouched")
    func firstRun() {
        #expect(!OnboardingView.needsSwitchConfirmation(picked: Self.other, current: Self.penn, hasChosenSchool: false))
    }

    @Test("the message names the current school and what is forgotten")
    func message() {
        #expect(OnboardingView.switchSchoolMessage(currentSchoolName: "Penn")
            == "this signs you out of Penn and forgets your saved password and duo trust.")
    }
}

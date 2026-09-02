import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for the pure helpers behind `AppState.submissionDiagnosticLines`
/// and `GradeWatcherStore.lastRefreshOutcomes` — the diagnostics added to
/// discriminate three otherwise-indistinguishable silent failure modes seen
/// on real devices when a submitted Canvas assignment still shows as
/// OVERDUE: (a) that course's grades fetch failing quietly, (b) the ICS UID
/// -> Canvas assignment id join failing for section-override events, and (c)
/// Canvas genuinely reporting the item as not submitted. Pure functions
/// only, so this needs no `AppState`, no `GradeWatcherStore` instance, no
/// `UserDefaults`, and no WebKit.
@MainActor
@Suite("Submission diagnostics")
struct SubmissionDiagnosticsTests {
    // MARK: - AppState.uidPrefixClass

    @Test("strips the domain and the numeric id, keeping only the shape")
    func uidPrefixClassStripsIDAndDomain() {
        #expect(
            AppState.uidPrefixClass("event-assignment-override-1234567@canvas.upenn.edu")
                == "event-assignment-override-"
        )
    }

    @Test("plain assignment UID strips to its own shape")
    func uidPrefixClassPlainAssignment() {
        #expect(AppState.uidPrefixClass("event-assignment-42@x") == "event-assignment-")
    }

    @Test("quiz UID strips to its own shape")
    func uidPrefixClassQuiz() {
        #expect(AppState.uidPrefixClass("event-quiz-5@x") == "event-quiz-")
    }

    @Test("empty UID returns the placeholder")
    func uidPrefixClassEmpty() {
        #expect(AppState.uidPrefixClass("") == "-")
    }

    @Test("a UID with no digit and no @ returns itself lowercased")
    func uidPrefixClassNoDigitNoAt() {
        #expect(AppState.uidPrefixClass("PlainLabel") == "plainlabel")
    }

    // MARK: - AppState.joinPath

    @Test("a direct assignments URL resolves via the url path")
    func joinPathResolvesViaURL() {
        let url = URL(string: "https://canvas.upenn.edu/courses/1/assignments/77")!
        #expect(AppState.joinPath(url: url, sourceID: "event-assignment-77@x") == "url")
    }

    @Test("a calendar-context URL with a plain assignment UID falls back to the uid path")
    func joinPathFallsBackToUID() {
        let url = URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_1")!
        #expect(AppState.joinPath(url: url, sourceID: "event-assignment-77@x") == "uid")
    }

    @Test("a section-override UID resolves via neither path — hypothesis (b)")
    func joinPathOverrideUIDResolvesToNone() {
        let url = URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_1")!
        #expect(AppState.joinPath(url: url, sourceID: "event-assignment-override-77@x") == "none")
    }

    @Test("no URL at all still falls back to the uid path")
    func joinPathNilURLFallsBackToUID() {
        #expect(AppState.joinPath(url: nil, sourceID: "event-assignment-77@x") == "uid")
    }

    // MARK: - GradeWatcherStore.fetchOutcomeLabel

    @Test("http failure reports only the status code, never the URL")
    func fetchOutcomeLabelHTTPNeverLeaksURL() {
        let error = CanvasGradesClient.Error.http(
            status: 403,
            url: URL(string: "https://canvas.upenn.edu/api/v1/x?token=SECRET")!
        )
        let label = GradeWatcherStore.fetchOutcomeLabel(for: error)
        #expect(label == "http 403")
        #expect(!label.contains("SECRET"))
    }

    @Test("session expired maps to its own label")
    func fetchOutcomeLabelSessionExpired() {
        #expect(GradeWatcherStore.fetchOutcomeLabel(for: CanvasGradesClient.Error.sessionExpired) == "sessionExpired")
    }

    @Test("decoding failure maps to decode")
    func fetchOutcomeLabelDecodingFailed() {
        #expect(GradeWatcherStore.fetchOutcomeLabel(for: CanvasGradesClient.Error.decodingFailed("x")) == "decode")
    }

    @Test("an unrelated error maps to the generic label")
    func fetchOutcomeLabelUnrelatedError() {
        struct Dummy: Swift.Error {}
        #expect(GradeWatcherStore.fetchOutcomeLabel(for: Dummy()) == "error")
    }
}

import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for `AppState.courseKnowledgeDiagnosticLines` — the pure
/// line-builder behind Settings → Diagnostics' "Course materials sync"
/// section, added after a shared-backend course sat with
/// `last_full_sync_at` null and `courseKnowledgeNotice`'s one line was the
/// only trace of why. A pure `static` function on `AppState` rather than an
/// instance method specifically so this needs no live `AppState` (no Canvas
/// session, no knowledge store, no `UserDefaults.lhf` round trip) — just
/// fixture inputs.
///
/// `@MainActor` because the function under test lives in an `extension
/// AppState`, and `AppState` itself is declared `@MainActor`; every member
/// of a `@MainActor` type — including a `static func` in an extension —
/// inherits that isolation unless marked otherwise.
@MainActor
@Suite("Course knowledge diagnostics")
struct CourseKnowledgeDiagnosticsTests {
    private func summary(_ id: String, _ code: String, section: String? = nil) -> CourseSummary {
        CourseSummary(courseID: id, code: code, name: code, url: nil, section: section)
    }

    private func document(_ courseID: String, kind: CourseDocument.Kind, sourceID: String) -> CourseDocument {
        CourseDocument(
            courseID: courseID,
            course: "PHYS 0151",
            kind: kind,
            sourceID: sourceID,
            title: "t",
            url: nil,
            text: "body"
        )
    }

    @Test("no trace this launch renders the 'none this launch' marker")
    func noTraceRendersNoneThisLaunch() {
        let knowledge = CourseKnowledgeBase(
            courses: [],
            documents: [document("1949400", kind: .syllabus, sourceID: "s1")],
            lastSyncedAt: nil,
            catalog: []
        )
        let lines = AppState.courseKnowledgeDiagnosticLines(
            trace: nil,
            knowledge: knowledge,
            summaries: [summary("1949400", "PHYS 0151")],
            storedVersion: 2,
            currentVersion: 3
        )

        #expect(lines.contains("stored sync version=2 current=3"))
        #expect(lines.contains { $0.hasPrefix("local knowledge: lastSyncedAt=never documents=1 catalog=0") })
        #expect(lines.contains("last run: none this launch"))
        // No trace means no "last run:" block header and no sub-lines.
        #expect(!lines.contains("last run:"))
    }

    @Test("a trace with one upload error renders the error line and counts")
    func traceWithUploadErrorRendersErrorLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let trace = CourseKnowledgeSyncTrace(
            startedAt: now,
            forced: true,
            courseIDs: ["1949400", "1949401"],
            manifestSucceeded: true,
            coursesFresh: ["1949401"],
            coursesToFetch: ["1949400"],
            fullyFetched: ["1949400"],
            collectorErrors: [],
            uploadBatches: 1,
            uploadedDocuments: 4,
            uploadError: "the internet connection appears to be offline.",
            skippedReason: nil,
            finishedAt: now.addingTimeInterval(12)
        )
        let knowledge = CourseKnowledgeBase(
            courses: [],
            documents: [
                document("1949400", kind: .syllabus, sourceID: "s1"),
                document("1949400", kind: .assignment, sourceID: "a1"),
            ],
            lastSyncedAt: now,
            catalog: []
        )

        let lines = AppState.courseKnowledgeDiagnosticLines(
            trace: trace,
            knowledge: knowledge,
            summaries: [
                summary("1949400", "PHYS 0151", section: "151"),
                summary("1949401", "PHYS 0151", section: "401"),
            ],
            storedVersion: 3,
            currentVersion: 3
        )

        #expect(lines.contains("last run:"))
        #expect(lines.contains { $0.contains("forced=true") && $0.contains("skipped=-") })
        #expect(lines.contains { $0.contains("manifest=ok") && $0.contains("fresh=[1949401]") && $0.contains("toFetch=[1949400]") && $0.contains("fullyFetched=[1949400]") })
        #expect(lines.contains { $0.contains("upload batches=1") && $0.contains("documents=4") && $0.contains("error=the internet connection appears to be offline.") })
        #expect(lines.contains { $0.contains("site 1949400 PHYS 0151 section 151:") && $0.contains("docs=2") && $0.contains("kinds assignment=1 syllabus=1") })
        #expect(lines.contains { $0.contains("site 1949401 PHYS 0151 section 401:") && $0.contains("docs=0") })
    }

    @Test("a run turned away by a guard records the skipped reason, not a full trace")
    func skippedRunRendersReason() {
        let trace = CourseKnowledgeSyncTrace(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            forced: false,
            courseIDs: [],
            manifestSucceeded: false,
            coursesFresh: [],
            coursesToFetch: [],
            fullyFetched: [],
            collectorErrors: [],
            uploadBatches: 0,
            uploadedDocuments: 0,
            uploadError: nil,
            skippedReason: "not stale",
            finishedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let lines = AppState.courseKnowledgeDiagnosticLines(
            trace: trace,
            knowledge: .empty,
            summaries: [],
            storedVersion: 3,
            currentVersion: 3
        )

        #expect(lines.contains { $0.contains("skipped=not stale") })
        #expect(lines.contains { $0.contains("manifest=failed") })
        #expect(lines.contains { $0.contains("upload batches=0 documents=0 error=-") })
    }

    @Test("collector errors are capped at 12 lines")
    func collectorErrorsCappedAtTwelve() {
        let errors = (1...20).map { "PHYS 0151 pages: error \($0)" }
        let trace = CourseKnowledgeSyncTrace(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            forced: false,
            courseIDs: ["1949400"],
            manifestSucceeded: true,
            coursesFresh: [],
            coursesToFetch: ["1949400"],
            fullyFetched: [],
            collectorErrors: errors,
            uploadBatches: 0,
            uploadedDocuments: 0,
            uploadError: nil,
            skippedReason: nil,
            finishedAt: nil
        )
        let lines = AppState.courseKnowledgeDiagnosticLines(
            trace: trace,
            knowledge: .empty,
            summaries: [],
            storedVersion: 3,
            currentVersion: 3
        )

        #expect(lines.contains("  collector errors=20"))
        let errorLines = lines.filter { $0.contains("PHYS 0151 pages: error") }
        #expect(errorLines.count == 12)
    }
}

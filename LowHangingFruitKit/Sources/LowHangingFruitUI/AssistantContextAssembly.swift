import Foundation
import LowHangingFruitKit

// MARK: – What the assistant is allowed to know
//
// The bridge between `AppState` (everything LHF holds about a student) and
// `AssistantContextDocument` (the byte-stable text handed to Claude). It is a
// deliberately small, deliberately explicit whitelist, and it lives in its own
// file for one reason: this function decides what leaves the device.
//
// Everywhere else in LHF, "what does this code touch" is a question about
// correctness. Here it is a question about disclosure. A future change that
// widens `work` to include, say, assignment URLs would be a two-line diff with
// no test failure and no visible symptom, and it would start shipping
// token-bearing Canvas links to a third party. So the rule for this file is
// that every field is passed across by name, one at a time — never by handing
// a whole model object to something that will serialize all of it.
//
// ## What is deliberately absent
//
// Three things a reader will expect to find and won't. (Since 2026-09-06 the
// first two reach the model by a different route: `CourseKnowledgeCollector`
// keeps syllabus prose and announcement bodies on-device, and
// `BackendAssistantResponder.retrievedExcerpts` sends the few passages that
// match a question as a separate field on the request — after the cache
// breakpoint, so nothing here has to change. This document stays the small,
// stable, cached part.)
//
//  1. **Syllabus prose.** `SyllabusSetupView` does ingest syllabus text — from
//     a PDF, a Canvas page, or pasted text — but `SyllabusParser` keeps only
//     the grading section and discards the rest. There is no attendance
//     policy, late-work policy or office-hours text anywhere on disk to send.
//     The context document says so in its own header, because a document full
//     of due dates and percentages *looks* complete and a model handed it will
//     otherwise invent a policy rather than admit the gap.
//
//  2. **Announcement bodies.** `AppState.announcementItems` sounds like it
//     holds announcements; it holds `Assignment` rows the Announcement
//     Watcher *extracted* from them (`source: .canvasAnnouncement`). The
//     `AnnouncementSourceText` those came from is transient — fetched,
//     extracted, dropped. So announcements reach the assistant as work items,
//     which is all they are by the time they are persisted, and the
//     `announcements:` parameter is passed empty rather than faked from them.
//
//  3. **Grades themselves.** Category *weights* go across, because "how much
//     is the final worth" is a question worth answering. Actual scores do not.
//     Nothing in the assistant's job needs to know what the student got.
//
// ## Stability
//
// The result is a prompt-cache prefix, so it has to be byte-identical between
// one question and the next or every turn re-pays for the whole document.
// `AssistantContextDocument.build` guarantees that for a given set of facts —
// it sorts everything and never reads a clock. This function's part of the
// bargain is not to introduce per-call variation of its own, which is why
// `isCompleted` is the only piece of derived state consulted and why nothing
// here formats a date. The current date reaches the model through the user
// turn instead (`BackendAssistantResponder.makeRequest`).

extension AppState {
    /// Renders this student's classes and work as the document the assistant
    /// reasons over. Returns `""` when there is nothing worth sending, which
    /// the responder treats as "no context" rather than as an empty document.
    func assistantContextDocument() -> String {
        let codes = allCourseCodes()
        guard !codes.isEmpty else { return "" }

        // `canvasCourseIDsByCode` (used here before 2026-09-09) is `[code:
        // id]` — one id per code, last-write-wins — so a code cross-listed
        // into two Canvas sites (`AppState.canvasCourseIDs()`'s own doc
        // comment explains why that happens) silently contributed only ONE
        // site's grading breakdown to the assistant, with the other site's
        // categories simply absent with no error. `canvasCourseIDs()` is
        // computed once here, id-keyed with possibly several ids per code,
        // and grouped by code below so `gradeCategoryFacts` can walk every
        // site behind a code instead of just the cached "primary" one.
        let courseIDs = canvasCourseIDs()
        let idsByCode = Dictionary(grouping: courseIDs.keys) { courseIDs[$0]! }

        let courses = codes.map { code -> AssistantContextDocument.CourseFacts in
            // A rename is cosmetic everywhere else in LHF, and it stays
            // cosmetic here: the code is the identity the document sorts and
            // joins on, and the display name rides along only so the model can
            // recognise the class if the student calls it by the name they
            // gave it.
            let shown = courseDisplayName(code)
            return AssistantContextDocument.CourseFacts(
                code: code,
                displayName: shown == code ? nil : shown,
                gradeCategories: gradeCategoryFacts(for: code, courseIDs: (idsByCode[code] ?? []).sorted())
            )
        }

        // Every pool the dashboard itself draws from. `announcementItems` is
        // included here — as work, which is what those rows are — rather than
        // in the `announcements:` parameter; see the note above.
        let pool = canvasItems + gradescopeItems + moduleReadingItems + announcementItems
        let work = pool.map { assignment in
            AssistantContextDocument.WorkFacts(
                course: assignment.course,
                title: assignment.title,
                due: assignment.dueAt,
                isCompleted: isCompleted(assignment),
                // `.event` is the model's own "there is nothing to hand in"
                // marker — lectures, office hours, an exam date — and the
                // cached no-submission set covers Canvas assignments Canvas
                // itself flags that way. Both matter to the assistant: "what
                // am I missing" must not list a lecture as outstanding work.
                nothingToSubmit: assignment.kind == .event || isAutoFiledNoSubmission(assignment),
                source: Self.assistantSourceLabel(for: assignment.source)
            )
        }

        return AssistantContextDocument.build(
            courses: courses,
            work: work,
            announcements: []
        )
    }

    /// This course's grading breakdown, if Grade Watcher has ever fetched it.
    ///
    /// The join runs code → Canvas course id(s) → categories, because Grade
    /// Watcher is keyed by Canvas's id while everything student-facing is
    /// keyed by the course code. `courseIDs` is every Canvas site behind this
    /// code (`AppState.canvasCourseIDs()`, not the single cached "primary"
    /// id) — a code with no ids at all (never watched, or added by hand)
    /// simply contributes no categories, and the document renders an
    /// explicit "not extracted from a syllabus" line for it — silence there
    /// would read as "this class has no grading scheme".
    ///
    /// `courseIDs` must already be sorted by the caller: this document is a
    /// prompt-cache prefix (see the CLAUDE.md trap on byte-stable caching),
    /// so the order categories are concatenated in has to be deterministic
    /// rather than whatever order a `Dictionary`'s keys happened to iterate
    /// in this launch. A category `name` that already appeared from an
    /// earlier id in the list is dropped — the two sites are the SAME
    /// course, so a rare identically-named category on both (a shared
    /// assignment group Canvas replicated to both sites) would otherwise
    /// double the document's account of it.
    private func gradeCategoryFacts(
        for code: String,
        courseIDs: [String]
    ) -> [AssistantContextDocument.GradeCategoryFacts] {
        var seenNames: Set<String> = []
        var facts: [AssistantContextDocument.GradeCategoryFacts] = []
        for courseID in courseIDs {
            for category in gradeWatcher.gradeCategories(courseID: courseID) {
                guard !seenNames.contains(category.name) else { continue }
                seenNames.insert(category.name)
                facts.append(
                    AssistantContextDocument.GradeCategoryFacts(
                        name: category.name,
                        // Canvas reports weights as percentages already; `nil`
                        // means the course is graded on raw points, not
                        // weighted categories, and the document distinguishes
                        // the two.
                        weightPercent: category.weight,
                        dropsLowest: category.dropLowest > 0
                    )
                )
            }
        }
        return facts
    }

    /// Source labels the document uses.
    ///
    /// Spelled out rather than derived from `Source.rawValue` so that renaming
    /// a case in the model can never silently change what is described to the
    /// model — and, more importantly, written **without a `default:`**. This is
    /// a disclosure boundary, so adding a seventh source should stop the build
    /// here and make someone decide what a third party gets told about it. A
    /// `default` would quietly fold that new source in as "canvas" and nobody
    /// would ever look at this function again.
    private static func assistantSourceLabel(for source: Assignment.Source) -> String {
        switch source {
        case .canvas:             return "canvas"
        case .gradescope:         return "gradescope"
        case .manual:             return "manual"
        case .canvasSuggestion:   return "canvas"
        case .canvasModules:      return "reading"
        case .canvasAnnouncement: return "announcement"
        }
    }
}

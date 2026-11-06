import SwiftUI
import LowHangingFruitKit

/// The megaphone sheet. Under the header, one control row laid out like the
/// dashboard's: the capsule switch (to-do · brief, `SmoothSegmentPicker`) and
/// the class filter menu (`ClassFilterMenu`), with the same chip under the row
/// while a class is picked. The body is the selected view alone:
///
/// - **to-do**: the tasks and exams the app found (drawn as the dashboard's own
///   `AssignmentCardView`, so a card can be swiped done or have its date
///   edited right here) and the changes the server's facts made to cards,
///   merged newest first (`AppState.announcementSheetTodo`).
/// - **brief**: every post the sheet lists (Canvas announcements and Ed posts)
///   and every fact the app held back for a look, newest first
///   (`AppState.announcementSheetBrief`). Which posts those are is decided in
///   `AppState+AnnouncementSheet.swift`, not here.
///
/// The class filter is the sheet's own, not the dashboard's, and starts at all
/// each time the sheet opens.
///
/// A post row is deliberately plain: class, date, a "NEW" mark, the title, and
/// one line of preview. The arrow and its "go to canvas" / "go to ed" caption
/// say a row opens elsewhere.
///
/// Rows marked "new" were unread when the sheet opened
/// (`AnnouncementReadState`).
struct AnnouncementFindsView: View {
    /// The found list as dashboard cards (`AppState.announcementFoundCards`).
    let found: [DashItem]
    /// The posts the sheet lists, already limited to classes the student still
    /// has and sorted newest first (`AppState.announcementSheetRecords`: the
    /// standing set and the keep-check).
    var records: [AnnouncementRecord] = []
    /// Ids that were unread when the sheet opened, so their rows can say
    /// "new" even though opening the sheet has just marked them seen. A
    /// find's `Assignment.id`, or a row's `AnnouncementReadState.key(for:)`.
    var newIDs: Set<String> = []
    /// (class key, display name) for the class menu, as the dashboard's own class
    /// menu is given them.
    var courses: [(key: String, name: String)] = []
    /// A found card was swiped done.
    var onComplete: (DashItem) -> Void = { _ in }
    /// The student saved (or reset, with nil) an edited date on a found card.
    var onSetDue: (Assignment, Date?) -> Void = { _, _ in }

    /// What facts from the server changed, grouped by the item they changed
    /// (`AppState.factChangeGroups`). Part of the to-do view.
    var factChanges: [FactChangeGroup] = []
    /// Facts the app would not apply on its own (`AppState.factReviewRows`).
    /// Part of the brief view.
    var factReviews: [FactReviewRow] = []

    /// The one class the sheet is narrowed to (a class key), nil for all of
    /// them. Starts nil every time the sheet opens, and is the sheet's own: it
    /// is not the dashboard's filter, which a student may have set for a
    /// different reason.
    @State private var classFilter: String?
    @State private var view: AnnouncementSheetView = .todo
    @State private var editing: Assignment?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.courseNameOverrides) private var courseNameOverrides

    private var selection: Set<String> { classFilter.map { [$0] } ?? [] }

    private var visibleFound: [DashItem] {
        AppState.announcementSheetNarrowed(found, toCourses: selection)
    }

    private var visibleRecords: [AnnouncementRecord] {
        AppState.announcementSheetNarrowed(records, toCourses: selection)
    }

    private var visibleChanges: [FactChangeGroup] {
        factChanges.filter { AppState.announcementSheetCourseMatches($0.courseCode, selection: selection) }
    }

    private var visibleReviews: [FactReviewRow] {
        factReviews.filter { AppState.announcementSheetCourseMatches($0.courseCode, selection: selection) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Lazy: a few hundred announcements would otherwise all be
                // built the moment the sheet opens.
                LazyVStack(alignment: .leading, spacing: 12) {
                    // The same shape cluster Profile and Grade Watcher open
                    // with, so this sheet reads as one of the app's pages
                    // rather than a bare system list.
                    SmoothFormHeader(
                        title: "Announcements",
                        accent: .smoothAnnouncementAccent,
                        spark: .smoothCobalt
                    )
                    .padding(.bottom, 4)

                    controlRow

                    if let classFilter {
                        ClassFilterChip(name: courses.first(where: { $0.key == classFilter })?.name ?? classFilter) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { self.classFilter = nil }
                        }
                    }

                    let now = Date()

                    // One view at a time, switched and filtered by the same
                    // controls as the dashboard. The owner's words
                    // (2026-11-06): "put at the top of announcements, like on
                    // the dashboard where it's todo and prev ... and to the
                    // right of that have the same sorting from the main
                    // dashboard", and "each announcement should look the
                    // same, remove the green line". So a student learns one
                    // set of controls; the class bubbles were a second
                    // vocabulary and were rejected, and the teal accent bar
                    // is gone so every row reads as one list. The switch
                    // names the view, so there are no section headers.
                    // There is no undo here; the card's own undo on the
                    // dashboard is the place for it.
                    switch view {
                    case .todo:
                        let todo = AppState.announcementSheetTodo(
                            found: visibleFound, changes: visibleChanges, records: records
                        )
                        if todo.isEmpty {
                            emptyLine(AnnouncementSheetCopy.emptyTodo)
                        } else {
                            ForEach(todo) { entry in
                                switch entry {
                                case .found(let item): foundCard(item)
                                case .change(let group): factChangeRow(group, now: now)
                                }
                            }
                        }
                    case .brief:
                        let brief = AppState.announcementSheetBrief(
                            records: visibleRecords, reviews: visibleReviews
                        )
                        if brief.isEmpty {
                            emptyLine(AnnouncementSheetCopy.emptyState)
                        } else {
                            ForEach(brief) { entry in
                                switch entry {
                                case .post(let record): recordRow(for: record, now: now)
                                case .review(let review): factReviewRow(review, now: now)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.smoothPaper.ignoresSafeArea())
            .tint(Color.smoothAnnouncementAccent)
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AnnouncementSheetCopy.dismiss) { dismiss() }
                }
            }
            .sheet(item: $editing) { assignment in
                EditDueSheet(
                    assignment: assignment,
                    overrideDate: Binding(
                        get: { found.first(where: { $0.id == assignment.id })?.dueOverride },
                        set: { onSetDue(assignment, $0) }
                    )
                )
            }
        }
    }

    // MARK: Facts

    /// Today, yesterday, else "nov 5": the post's date, in the record rows' style.
    private func factDateLabel(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day()).lowercased()
    }

    /// The dashboard's control row: the switch takes the width, the class menu
    /// sits flush right (`ContentView`'s own layout).
    private var controlRow: some View {
        HStack(spacing: 10) {
            SmoothSegmentPicker(selection: $view) { $0.label }
            if !courses.isEmpty {
                ClassFilterMenu(courses: courses, selection: $classFilter)
            }
        }
    }

    /// The one chrome every brief row wears, so a post row and a review row
    /// cannot differ: padding 14 on a rounded `v2DoneCard`, content leading
    /// and the link-out mark trailing. `link` makes the whole row a link.
    @ViewBuilder
    private func rowChrome<Content: View>(
        url: URL?, caption: String, hint: String, canvasAction: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let inner = HStack(spacing: 12) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if url != nil {
                LinkOutMark(caption: caption)
            }
        }
        Group {
            if let url {
                if canvasAction {
                    Link(destination: url) { inner }
                        .buttonStyle(.plain)
                        .environment(\.openURL, CanvasAppLink.action)
                        .accessibilityHint(hint)
                } else {
                    Link(destination: url) { inner }
                        .buttonStyle(.plain)
                        .accessibilityHint(hint)
                }
            } else {
                inner
            }
        }
        .padding(14)
        .background(Color.v2DoneCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func factRowChrome<Content: View>(
        url: URL?, hint: String, @ViewBuilder content: () -> Content
    ) -> some View {
        rowChrome(url: url, caption: AnnouncementSheetCopy.goToCanvas, hint: hint, canvasAction: true, content: content)
    }

    private func factChip(_ code: String, date: Date?, isNew: Bool, now: Date) -> some View {
        HStack(spacing: 6) {
            Text(AppState.factCourseLabel(code, overrides: courseNameOverrides).uppercased())
                .font(.lhfMono(9.5, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Color.smoothAnnouncementAccent)
            if let label = factDateLabel(date, now: now) {
                Text(label)
                    .font(.lhfMono(9.5))
                    .foregroundStyle(Color.smoothMuted)
            }
            if isNew {
                Text("NEW")
                    .font(.lhfMono(8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.smoothPaper)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.smoothAnnouncementAccent))
            }
        }
    }

    /// One item and the one-word changes made to it. An undone fact is the
    /// same row, dimmed and struck through.
    private func factChangeRow(_ group: FactChangeGroup, now: Date) -> some View {
        let isNew = group.rows.contains { newIDs.contains(AnnouncementReadState.factKey($0.id)) }
        return factRowChrome(url: group.url, hint: AnnouncementSheetCopy.canvasLinkHint) {
            VStack(alignment: .leading, spacing: 6) {
                factChip(group.courseCode, date: group.postedAt, isNew: isNew, now: now)
                Text(group.title)
                    .font(.lhfAssignmentTitle(17))
                    .foregroundStyle(Color.smoothInk)
                    .strikethrough(group.isUndone)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(group.rows.map(\.word).joined(separator: " \u{00B7} "))
                    .font(.lhfMono(9.5))
                    .foregroundStyle(Color.smoothMuted)
            }
            .opacity(group.isUndone ? 0.5 : 1)
        }
    }

    /// A fact the app held back: the instructor's words and the post.
    private func factReviewRow(_ review: FactReviewRow, now: Date) -> some View {
        factRowChrome(url: review.url, hint: AnnouncementSheetCopy.canvasLinkHint) {
            VStack(alignment: .leading, spacing: 6) {
                factChip(review.courseCode, date: review.postedAt, isNew: false, now: now)
                Text(review.quote)
                    .font(.lhfSecondary(13))
                    .foregroundStyle(Color.smoothInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.lhfSecondary(14))
            .foregroundStyle(Color.smoothMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    /// A found task or exam as the dashboard's own card.
    private func foundCard(_ item: DashItem) -> some View {
        AssignmentCardView(
            item: item,
            onComplete: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    onComplete(item)
                }
            },
            onEdit: { editing = item.assignment },
            isExamOverride: item.examStyleOverride,
            isNew: newIDs.contains(item.id)
        )
    }

    @ViewBuilder
    private func recordRow(for record: AnnouncementRecord, now: Date) -> some View {
        let link = record.safeWebURL
        let isNew = newIDs.contains(AnnouncementReadState.key(for: record))
        rowChrome(
            url: link,
            caption: record.isEd ? AnnouncementSheetCopy.goToEd : AnnouncementSheetCopy.goToCanvas,
            hint: AnnouncementSheetCopy.linkHint(for: record),
            // A Canvas post opens the Canvas Student app like a card's link
            // does (the scheme branch, confirmed on Marco's phone 2026-11-06);
            // an Ed post keeps the system's own opening.
            canvasAction: !record.isEd
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(record.displayCourse(overrides: courseNameOverrides).uppercased())
                        .font(.lhfMono(9.5, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Color.smoothAnnouncementAccent)
                    if let posted = record.postedLabel(now: now) {
                        Text(posted)
                            .font(.lhfMono(9.5))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    // Only an Ed row says where it is from, in the date's own
                    // style: its arrow opens Ed, not Canvas.
                    if let source = AnnouncementSheetCopy.sourceWord(for: record) {
                        Text(source)
                            .font(.lhfMono(9.5))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    if isNew {
                        Text("NEW")
                            .font(.lhfMono(8, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Color.smoothPaper)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.smoothAnnouncementAccent))
                    }
                }
                Text(AnnouncementSheetCopy.title(for: record))
                    .font(.lhfAssignmentTitle(17))
                    .foregroundStyle(Color.smoothInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !record.snippet.isEmpty {
                    Text(record.snippet)
                        .font(.lhfSecondary(13))
                        .foregroundStyle(Color.smoothMuted)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The arrow that says a row opens elsewhere, with where under it. One view
/// for fact rows and post rows so the two cannot drift. Fixed-size so the
/// caption never wraps; VoiceOver already gets the row's own hint.
private struct LinkOutMark: View {
    let caption: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
            Text(caption)
                .font(.lhfMono(8))
                .multilineTextAlignment(.center)
                .fixedSize()
        }
        .foregroundStyle(Color.smoothMuted)
        .accessibilityHidden(true)
    }
}

extension AnnouncementRecord {
    /// The class label for a row: the student's rename when there is one
    /// (keyed on the raw course code, as `Assignment.displayCourse(overrides:)`
    /// is), else the code, else "Misc".
    func displayCourse(overrides: [String: String]) -> String {
        if let custom = overrides[courseCode]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        let trimmed = courseCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Misc" : trimmed
    }
}

/// The sheet's fixed words and the per-row text rules that are not just
/// layout, kept pure so a test can pin them. The owner's brief for this sheet
/// was "way too much text; everything as simple as possible", so the rules
/// here are mostly about what is left out.
enum AnnouncementSheetCopy {
    /// Shown under "announcements" when that list is empty. Not "in the last 7
    /// days": the window is not something a student needs to be told. Since
    /// 2026-10-18 this is reachable by every student who opens the megaphone
    /// early on: the header button no longer hides itself while the list is
    /// empty, so this line is what an empty list says. It stays one short
    /// lowercase line, on purpose (the owner wants the least possible text).
    /// The found list has no such line; it is hidden when empty.
    static let emptyState = "no announcements"
    /// The sheet's dismiss button. The owner's wording: it names where the
    /// student lands, which "done" did not.
    static let dismiss = "back to assignments"
    /// Shown in the to-do view when nothing is to do.
    static let emptyTodo = "nothing to do"
    /// The sheet's two views: what to do, and what was said. (Their labels on
    /// the switch are `AnnouncementSheetView.label`.)
    static let todoHeader = "to-do"
    static let briefHeader = "brief"
    /// Under the arrow on a row that opens elsewhere.
    static let goToCanvas = "go to canvas"
    static let goToEd = "go to ed"
    /// A row whose post came without a title.
    static let untitled = "untitled"

    /// The most the header badge counts to before it says "99+". A student
    /// back from a long break can have a few hundred unread; the number has to
    /// fit a 48pt circle's rim without clipping, and past two digits the exact
    /// count tells them nothing the sheet does not. VoiceOver is still given
    /// the true count (`ContentView.announcementFindsButton`).
    static let badgeCap = 99

    /// The text inside the megaphone's unread badge.
    static func badgeText(_ unread: Int) -> String {
        unread > badgeCap ? "\(badgeCap)+" : "\(unread)"
    }

    static let canvasLinkHint = "opens the original announcement"
    static let edLinkHint = "opens the post in ed"

    /// The row's title, or "untitled" when it is blank or only whitespace.
    static func title(for record: AnnouncementRecord) -> String {
        let trimmed = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitled : trimmed
    }

    /// The single word that marks where a row came from, or nil for Canvas
    /// (the default, which needs no word).
    static func sourceWord(for record: AnnouncementRecord) -> String? {
        record.isEd ? "ed" : nil
    }

    /// What VoiceOver says a tap on the row does.
    static func linkHint(for record: AnnouncementRecord) -> String {
        record.isEd ? edLinkHint : canvasLinkHint
    }
}

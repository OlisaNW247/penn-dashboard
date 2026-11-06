import SwiftUI
import LowHangingFruitKit

/// The megaphone sheet. A row of class bubbles at the top ("all" first, then
/// one per class), and under it exactly two sections, whatever the bubbles say:
///
/// - **to-do**: the tasks and exams the app found (drawn as the dashboard's own
///   `AssignmentCardView`, so a card can be swiped done or have its date
///   edited right here) and the changes the server's facts made to cards,
///   merged newest first (`AppState.announcementSheetTodo`). Hidden when empty.
/// - **brief**: every post the sheet lists (Canvas announcements and Ed posts)
///   and every fact the app held back for a look, newest first
///   (`AppState.announcementSheetBrief`). Which posts those are is decided in
///   `AppState+AnnouncementSheet.swift`, not here.
///
/// The bubbles filter both sections: tapping a class from "all" switches to
/// just that class, tapping another adds it, tapping a selected one removes
/// it, and removing the last goes back to all
/// (`AppState.announcementSheetTap`). The selection is the sheet's own, not the
/// dashboard's class filter, and it starts at all each time the sheet opens.
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
    /// (class key, display name) for the bubbles, as the dashboard's own class
    /// menu is given them.
    var courses: [(key: String, name: String)] = []
    /// A found card was swiped done.
    var onComplete: (DashItem) -> Void = { _ in }
    /// The student saved (or reset, with nil) an edited date on a found card.
    var onSetDue: (Assignment, Date?) -> Void = { _, _ in }

    /// What facts from the server changed, grouped by the item they changed
    /// (`AppState.factChangeGroups`). Part of the to-do section.
    var factChanges: [FactChangeGroup] = []
    /// Facts the app would not apply on its own (`AppState.factReviewRows`).
    /// Part of the brief section.
    var factReviews: [FactReviewRow] = []

    /// The classes the sheet is narrowed to (class keys), empty for all of
    /// them. Starts empty every time the sheet opens, and is the sheet's own:
    /// it is not the dashboard's filter, which a student may have set for a
    /// different reason.
    @State private var selection: Set<String> = []
    @State private var editing: Assignment?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.courseNameOverrides) private var courseNameOverrides

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

                    if !courses.isEmpty {
                        classBubbles
                    }

                    let now = Date()
                    let todo = AppState.announcementSheetTodo(
                        found: visibleFound, changes: visibleChanges, records: records
                    )
                    let brief = AppState.announcementSheetBrief(
                        records: visibleRecords, reviews: visibleReviews
                    )

                    // Two sections, whatever the bubbles say: "one tab", in
                    // the owner's words (2026-11-06), after the sheet had
                    // grown four groups (changed, needs a look, found,
                    // announcements) plus a different single list while a
                    // class was selected, and "the sections don't make
                    // sense". Keeping four groups was rejected: a student
                    // asks "what do I have to do" and "what was said", not
                    // "what did a fact change". There is no undo here; the
                    // card's own undo on the dashboard is the place for it.
                    if !todo.isEmpty {
                        SmoothSectionHeader(AnnouncementSheetCopy.todoHeader, accent: .smoothAnnouncementAccent)
                            .padding(.top, 4)
                        ForEach(todo) { entry in
                            switch entry {
                            case .found(let item): foundCard(item)
                            case .change(let group): factChangeRow(group, now: now)
                            }
                        }
                    }

                    SmoothSectionHeader(AnnouncementSheetCopy.briefHeader, accent: .smoothAnnouncementAccent)
                        .padding(.top, todo.isEmpty ? 4 : 12)
                    if brief.isEmpty {
                        emptyLine
                    } else {
                        ForEach(brief) { entry in
                            switch entry {
                            case .post(let record): recordRow(for: record, now: now)
                            case .review(let review): factReviewRow(review, now: now)
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

    @ViewBuilder
    private func factRowChrome<Content: View>(
        url: URL?, hint: String, @ViewBuilder content: () -> Content
    ) -> some View {
        let inner = HStack(spacing: 12) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if url != nil {
                LinkOutMark(caption: AnnouncementSheetCopy.goToCanvas)
            }
        }
        HStack(spacing: 12) {
            Capsule()
                .fill(Color.smoothAnnouncementAccent)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
            if let url {
                Link(destination: url) { inner }
                    .buttonStyle(.plain)
                    .environment(\.openURL, CanvasAppLink.action)
                    .accessibilityHint(hint)
            } else {
                inner
            }
        }
        .padding(14)
        .background(Color.v2DoneCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var emptyLine: some View {
        Text(AnnouncementSheetCopy.emptyState)
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

    /// "all" and then one bubble per class, wrapped onto as many rows as the
    /// width needs (two, for a usual term): the same capsules and the same
    /// flow layout the add sheet's class picker uses (`CoursePicker`), so a
    /// class is the same colour here as there. A selected class is filled in
    /// its own colour; "all" is the sheet's teal. Which bubbles are lit and
    /// what a tap does is `AppState.announcementSheetTap`.
    ///
    /// Wrapped, not one scrolling row: the owner's call on first sight
    /// (2026-10-23). A row that scrolls hides the classes past the screen's
    /// edge, so a class you cannot see is a class you cannot pick.
    private var classBubbles: some View {
        CoursePickerFlowLayout(spacing: 6) {
            bubble(
                AnnouncementSheetCopy.allBubble, isSelected: selection.isEmpty,
                accent: .smoothAnnouncementAccent, ink: .smoothAnnouncementAccent, onFill: .smoothPaper
            ) { tap(nil) }
            ForEach(courses, id: \.key) { course in
                bubble(
                    course.name, isSelected: selection.contains(course.key),
                    accent: courseAccent(for: course.key), ink: courseAccentInk(for: course.key),
                    onFill: Color(hex: 0x1B1714)
                ) { tap(course.key) }
            }
        }
        .padding(.vertical, 2)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func tap(_ course: String?) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            selection = AppState.announcementSheetTap(course, selection: selection)
        }
    }

    /// One capsule, drawn as `CoursePicker`'s chips are: uppercased mono label,
    /// a solid pastel when selected and a quiet tint with a hairline when not.
    /// A selected capsule's label is `onFill` and an unselected one's is `ink`:
    /// the pastels are fills, and type on them takes a fixed colour in both
    /// modes (the pastels do not change after sunset) where type on the page
    /// takes the accent's ink.
    private func bubble(
        _ label: String,
        isSelected: Bool,
        accent: Color,
        ink: Color,
        onFill: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // A size down from `CoursePicker`'s chips so a usual term's
            // classes and "all" fit in one or two rows (the owner's ask).
            Text(label.uppercased())
                .font(.lhfMono(11, weight: .semibold))
                .tracking(0.3)
                .lineLimit(1)
                .foregroundStyle(isSelected ? onFill : ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? accent : accent.opacity(0.14)))
                .overlay(Capsule().stroke(accent.opacity(isSelected ? 0 : 0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func recordRow(for record: AnnouncementRecord, now: Date) -> some View {
        let link = record.safeWebURL
        let isNew = newIDs.contains(AnnouncementReadState.key(for: record))
        let content = HStack(spacing: 12) {
            Capsule()
                .fill(Color.smoothAnnouncementAccent)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)

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
            .frame(maxWidth: .infinity, alignment: .leading)

            // Only when the URL is https with a host (`safeWebURL`): the arrow
            // appears exactly when the whole row is a working link.
            if link != nil {
                LinkOutMark(caption: record.isEd ? AnnouncementSheetCopy.goToEd : AnnouncementSheetCopy.goToCanvas)
            }
        }
        .padding(14)
        .background(Color.v2DoneCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        if let link {
            Link(destination: link) { content }
                .buttonStyle(.plain)
                .accessibilityHint(AnnouncementSheetCopy.linkHint(for: record))
        } else {
            content
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
    /// The first bubble, before the classes. Drawn uppercased like the others.
    static let allBubble = "all"
    /// The sheet's two sections: what to do, and what was said.
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

import SwiftUI
import LowHangingFruitKit

/// The megaphone sheet. Two lists, top to bottom, both narrowed by one class
/// filter:
///
/// - **found**: tasks the Announcement Watcher found in Canvas announcements
///   and Ed posts, and the exams the class has found (the syllabus's too),
///   that are still ahead of the student. Drawn as the dashboard's own
///   `AssignmentCardView`, so an exam keeps its black-on-white (or inverted)
///   exam card and a card can be swiped done or have its date edited right
///   here. Hidden altogether when there are none.
/// - **announcements**: the Canvas announcements and the Ed announcements and
///   pinned posts from the last 7 days, newest first, whether or not the
///   extractor found anything in them. What decides each list's rows is
///   `AppState+AnnouncementSheet.swift`; this view only draws what it is
///   given, plus the class filter.
///
/// An announcement row is deliberately plain: class, date, a "NEW" mark, the
/// title, and one line of preview. The arrow alone says a row opens elsewhere;
/// an Ed row also carries the word "ed" in its meta line so it is not mistaken
/// for Canvas.
///
/// Rows marked "new" were unread when the sheet opened
/// (`AnnouncementReadState`).
struct AnnouncementFindsView: View {
    /// The found list as dashboard cards (`AppState.announcementFoundCards`).
    let found: [DashItem]
    /// The announcements within the 7-day window, already limited to classes
    /// the student still has and sorted newest first
    /// (`AppState.announcementSheetRecords`).
    var records: [AnnouncementRecord] = []
    /// Ids that were unread when the sheet opened, so their rows can say
    /// "new" even though opening the sheet has just marked them seen. A
    /// find's `Assignment.id`, or a row's `AnnouncementReadState.key(for:)`.
    var newIDs: Set<String> = []
    /// (class key, display name) for the filter, as the dashboard's own class
    /// menu is given them.
    var courses: [(key: String, name: String)] = []
    /// A found card was swiped done.
    var onComplete: (DashItem) -> Void = { _ in }
    /// The student saved (or reset, with nil) an edited date on a found card.
    var onSetDue: (Assignment, Date?) -> Void = { _, _ in }

    /// The class the sheet is narrowed to, or nil for all of them. Starts at
    /// all classes every time the sheet opens, and is the sheet's own: it is
    /// not the dashboard's filter, which a student may have set for a
    /// different reason.
    @State private var classFilter: String?
    @State private var editing: Assignment?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.courseNameOverrides) private var courseNameOverrides

    private var visibleFound: [DashItem] {
        AppState.announcementSheetNarrowed(found, toCourse: classFilter)
    }

    private var visibleRecords: [AnnouncementRecord] {
        AppState.announcementSheetNarrowed(records, toCourse: classFilter)
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

                    classFilterRow

                    let foundNow = visibleFound
                    if !foundNow.isEmpty {
                        SmoothSectionHeader(AnnouncementSheetCopy.foundHeader, accent: .smoothAnnouncementAccent)
                            .padding(.top, 4)
                        ForEach(foundNow) { item in
                            AssignmentCardView(
                                item: item,
                                onComplete: {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                        onComplete(item)
                                    }
                                },
                                onEdit: { editing = item.assignment },
                                isExamOverride: item.examStyleOverride,
                                isNew: newIDs.contains(item.id)
                            )
                        }
                    }

                    SmoothSectionHeader(AnnouncementSheetCopy.announcementsHeader, accent: .smoothAnnouncementAccent)
                        .padding(.top, foundNow.isEmpty ? 4 : 12)
                    let shown = visibleRecords
                    if shown.isEmpty {
                        Text(AnnouncementSheetCopy.emptyState)
                            .font(.lhfSecondary(14))
                            .foregroundStyle(Color.smoothMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    } else {
                        let now = Date()
                        // Which of these posts a find came from, for the
                        // small "task found" tag. Joined on the id
                        // inside the find's ledger `sourceID`: a Canvas
                        // announcement id, or an Ed document id.
                        let withFinds = Set(found.compactMap {
                            AnnouncementRecord.recordID(fromFindSourceID: $0.assignment.sourceID)
                        })
                        ForEach(shown) { record in
                            recordRow(for: record, now: now, hasFind: withFinds.contains(record.id))
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

    /// The dashboard's class filter, as it is there: the cobalt menu button,
    /// and once a class is picked a chip naming it (in that class's own colour,
    /// as in the add sheet's class picker) that clears it. The same
    /// `ClassFilterMenu`, so the two cannot drift apart.
    private var classFilterRow: some View {
        HStack(spacing: 8) {
            ClassFilterMenu(courses: courses, selection: $classFilter)
            if let key = classFilter {
                ClassFilterChip(
                    name: courses.first { $0.key == key }?.name ?? key,
                    accent: courseAccent(for: key),
                    ink: courseAccentInk(for: key)
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        classFilter = nil
                    }
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func recordRow(for record: AnnouncementRecord, now: Date, hasFind: Bool) -> some View {
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
                    if hasFind {
                        Text("task found")
                            .font(.lhfMono(8, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(Color.smoothAnnouncementAccent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay(Capsule().stroke(Color.smoothAnnouncementAccent, lineWidth: 1))
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
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.smoothMuted)
                    .accessibilityHidden(true)
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
    static let foundHeader = "found"
    static let announcementsHeader = "announcements"
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

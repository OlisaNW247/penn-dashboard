import SwiftUI
import LowHangingFruitKit

/// The megaphone sheet. Two lists:
///
/// - **tasks found**: tasks and reference material the Announcement Watcher
///   extracted, kept off the owed-work dashboard. Shown only when there are
///   some.
/// - **all announcements**: every Canvas announcement from the last 60 days
///   for the student's classes, plus the Ed Discussion announcements and
///   pinned posts already on the phone, newest first, whether or not the
///   extractor found anything in it. This is the list students meant when
///   they said "announcements aren't there": the sheet used to be the first
///   list only.
///
/// Rows are deliberately plain: class, date, a "NEW" mark, the title, and one
/// line of preview. The arrow alone says a row opens elsewhere; an Ed row also
/// carries the word "ed" in its meta line so it is not mistaken for Canvas.
///
/// Rows marked "new" were unread when the sheet opened
/// (`AnnouncementReadState`).
struct AnnouncementFindsView: View {
    let items: [Assignment]
    /// The plain announcements, already filtered to selected classes and
    /// sorted newest first (`AppState.announcementRecordsOnPage`).
    var records: [AnnouncementRecord] = []
    /// Ids that were unread when the sheet opened, so their rows can say
    /// "new" even though opening the sheet has just marked them seen. A
    /// find's `Assignment.id`, or a row's `AnnouncementReadState.key(for:)`.
    var newIDs: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.courseNameOverrides) private var courseNameOverrides

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

                    if items.isEmpty && records.isEmpty {
                        Text(AnnouncementSheetCopy.emptyState)
                            .font(.lhfSecondary(14))
                            .foregroundStyle(Color.smoothMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 36)
                    } else {
                        if !items.isEmpty {
                            SmoothSectionHeader("tasks found", accent: .smoothAnnouncementAccent)
                                .padding(.top, 4)
                            ForEach(items) { item in
                                row(for: item)
                            }
                        }
                        if !records.isEmpty {
                            SmoothSectionHeader("all announcements", accent: .smoothAnnouncementAccent)
                                .padding(.top, items.isEmpty ? 4 : 12)
                            let now = Date()
                            // Which of these posts a find came from, for the
                            // small "task found" tag. Joined on the id
                            // inside the find's ledger `sourceID`.
                            let withFinds = Set(items.compactMap {
                                AnnouncementRecord.announcementID(fromFindSourceID: $0.sourceID)
                            })
                            ForEach(records) { record in
                                recordRow(for: record, now: now, hasFind: withFinds.contains(record.id))
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
                    Button("done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: Assignment) -> some View {
        let link = item.sourceLinks.first
        let content = HStack(spacing: 12) {
            Capsule()
                .fill(Color.smoothAnnouncementAccent)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.displayCourse(overrides: courseNameOverrides).uppercased())
                        .font(.lhfMono(9.5, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Color.smoothAnnouncementAccent)
                    if newIDs.contains(item.id) {
                        Text("NEW")
                            .font(.lhfMono(8, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Color.smoothPaper)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.smoothAnnouncementAccent))
                    }
                }
                Text(item.title)
                    .font(.lhfAssignmentTitle(17))
                    .foregroundStyle(Color.smoothInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let dueAt = item.dueAt {
                    Text(dueAt.formatted(date: .abbreviated, time: .shortened).lowercased())
                        .font(.lhfMono(10))
                        .foregroundStyle(Color.smoothMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The arrow alone is the affordance (a text label beside it was
            // more words than the row needed). `sourceLinks` (not
            // `item.url`) so it appears exactly when a tappable, https
            // destination exists; the hint tells VoiceOver where it goes.
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
            Link(destination: link.url) { content }
                .buttonStyle(.plain)
                .accessibilityHint(AnnouncementSheetCopy.canvasLinkHint)
        } else {
            content
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
    /// Shown when there is nothing at all to list. Not "in the last 60 days":
    /// the window is not something a student needs to be told.
    static let emptyState = "no announcements"
    /// A row whose post came without a title.
    static let untitled = "untitled"
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

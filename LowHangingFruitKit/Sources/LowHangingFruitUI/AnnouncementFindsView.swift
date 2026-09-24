import SwiftUI
import LowHangingFruitKit

/// The megaphone sheet: tasks and reference material the Announcement
/// Watcher found, kept off the owed-work dashboard. Rows marked "new" were
/// unread when the sheet opened (`AnnouncementReadState`).
struct AnnouncementFindsView: View {
    let items: [Assignment]
    /// Ids that were unread when the sheet opened, so their rows can say
    /// "new" even though opening the sheet has just marked them seen.
    var newIDs: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.courseNameOverrides) private var courseNameOverrides

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // The same shape cluster Profile and Grade Watcher open
                    // with, so this sheet reads as one of the app's pages
                    // rather than a bare system list.
                    SmoothFormHeader(
                        title: "Announcements",
                        accent: .smoothAnnouncementAccent,
                        spark: .smoothCobalt
                    )
                    .padding(.bottom, 4)

                    if items.isEmpty {
                        Text("no announcements")
                            .font(.lhfSecondary(14))
                            .foregroundStyle(Color.smoothMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 36)
                    } else {
                        ForEach(items) { item in
                            row(for: item)
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
                    .fixedSize(horizontal: false, vertical: true)
                if let dueAt = item.dueAt {
                    Text(dueAt.formatted(date: .abbreviated, time: .shortened).lowercased())
                        .font(.lhfMono(10))
                        .foregroundStyle(Color.smoothMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.url != nil {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.smoothMuted)
            }
        }
        .padding(14)
        .background(Color.v2DoneCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        if let url = item.url {
            Link(destination: url) { content }
                .buttonStyle(.plain)
                .accessibilityHint("opens the original announcement")
        } else {
            content
        }
    }
}

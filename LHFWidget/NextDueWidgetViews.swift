import WidgetKit
import SwiftUI
import LowHangingFruitKit

// The widget extension can't import LowHangingFruitUI (see project.yml), so
// this is a small, deliberate duplicate of `Color(hex:)` from DesignSystem.swift.
extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >>  8) & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// The app's palette, scoped to what the widget needs. Kept in one place so
/// the Home Screen views read as calm and consistent with the main app.
private enum Palette {
    static let paper = Color(hex: 0xF4F1EC)
    static let ink = Color(hex: 0x211F1B)
    static let courseGrey = Color(hex: 0xA39C8E)
}

struct NextDueEntryView: View {
    let entry: NextDueEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallView(item: entry.snapshot.items.first)
        case .systemMedium:
            MediumView(items: Array(entry.snapshot.items.prefix(3)))
        case .accessoryInline:
            InlineView(item: entry.snapshot.items.first)
        case .accessoryCircular:
            CircularView(items: entry.snapshot.items)
        case .accessoryRectangular:
            RectangularView(items: Array(entry.snapshot.items.prefix(2)))
        default:
            SmallView(item: entry.snapshot.items.first)
        }
    }
}

// MARK: - Home Screen: Small

private struct SmallView: View {
    let item: WidgetItem?

    var body: some View {
        HStack(spacing: 0) {
            spine
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(Palette.paper, for: .widget)
    }

    @ViewBuilder
    private var spine: some View {
        if let item {
            Color(hex: WidgetUrgency(due: item.dueAt).spineHex)
                .frame(width: 4)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let item {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.course.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Palette.courseGrey)
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let due = item.dueAt {
                    Text(due, style: .relative)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: WidgetUrgency(due: due).spineHex))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack {
                Spacer()
                Text("all clear")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.courseGrey)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        }
    }
}

// MARK: - Home Screen: Medium

private struct MediumView: View {
    let items: [WidgetItem]

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items, id: \.self) { item in
                        NextDueRow(item: item)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .containerBackground(Palette.paper, for: .widget)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("nothing due. you're caught up.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.courseGrey)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row of the medium widget's up-to-three list: an urgency dot, the
/// course + title, and a live relative due time.
private struct NextDueRow: View {
    let item: WidgetItem

    private var urgency: WidgetUrgency { WidgetUrgency(due: item.dueAt) }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: urgency.spineHex))
                .frame(width: 6, height: 6)
            Text(item.course)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.courseGrey)
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let due = item.dueAt {
                Text(due, style: .relative)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: urgency.spineHex))
            }
        }
    }
}

// MARK: - Lock Screen: Inline

private struct InlineView: View {
    let item: WidgetItem?

    var body: some View {
        if let item {
            let urgency = WidgetUrgency(due: item.dueAt)
            if let due = item.dueAt {
                Text("\(urgency.emoji) \(item.title) · \(due, style: .relative)")
            } else {
                Text("\(urgency.emoji) \(item.title)")
            }
        } else {
            Text("lhf · all clear")
        }
    }
}

// MARK: - Lock Screen: Circular

/// Accessory widgets render monochrome regardless of the colors we set, so
/// this leans on a number + label rather than the spine palette.
private struct CircularView: View {
    let items: [WidgetItem]

    private var dueWithin24h: Int {
        let now = Date()
        return items.filter { item in
            guard let due = item.dueAt else { return false }
            let s = due.timeIntervalSince(now)
            return s >= 0 && s < 86_400
        }.count
    }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if dueWithin24h > 0 {
                VStack(spacing: 0) {
                    Text("\(dueWithin24h)")
                        .font(.system(size: 20, weight: .bold))
                    Text("due")
                        .font(.system(size: 9))
                }
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 18))
            }
        }
    }
}

// MARK: - Lock Screen: Rectangular

private struct RectangularView: View {
    let items: [WidgetItem]

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(alignment: .leading, spacing: 2) {
                if let first = items.first {
                    firstLine(for: first)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if items.count > 1 {
                        Text(items[1].title)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("all clear")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func firstLine(for item: WidgetItem) -> Text {
        // Accessory widgets render monochrome, so — unlike the color-spined
        // Home Screen — the urgency emoji is the only cue that separates an
        // overdue item from an upcoming one here.
        let dot = Text("\(WidgetUrgency(due: item.dueAt).emoji) ")
        guard let due = item.dueAt else { return dot + Text(item.title) }
        return dot + Text("\(item.title) · \(due, style: .relative)")
    }
}

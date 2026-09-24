import SwiftUI
import LowHangingFruitKit

/// The dashboard's view switch: todo · all · prev, always visible, with a
/// highlight that slides to the one you're on. It takes every point of the
/// row the buttons to its right don't need — the widest, easiest target on
/// the screen for the thing students do most — and the buttons sit flush
/// right. (It was briefly a "todo ▾" menu, which hid two of the three
/// views behind an extra tap; the dice button that shared this row lives
/// on in the `v8-dice-toggle` branch.)
struct DashViewPicker: View {
    @Binding var selection: DashFilter
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DashFilter.allCases) { filter in
                let isActive = filter == selection
                Text(filter.label)
                    .font(.lhfSans(14, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Color.smoothInk : Color.smoothMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background {
                        if isActive {
                            Capsule()
                                .fill(Color.smoothRule.opacity(0.72))
                                .matchedGeometryEffect(id: "active", in: indicator)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { select(filter) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(filter.label)
                    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(Color.smoothSurface.opacity(0.58), in: Capsule())
        .overlay { Capsule().stroke(Color.smoothRule.opacity(0.72), lineWidth: 1.25) }
    }

    private func select(_ filter: DashFilter) {
        guard filter != selection else { return }
        lhfHapticLight()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            selection = filter
        }
    }
}

/// "Sort by class": narrows every view — todo, all and prev — to one
/// course. A menu rather than a row of chips because a student has five or
/// six classes and the row has room for one 38pt button. The icon fills in
/// while a class is picked, and `ClassFilterChip` under the row says which
/// one and clears it, so a filtered list never looks like missing work.
struct ClassFilterMenu: View {
    /// (course key, display name), already sorted by the caller.
    let courses: [(key: String, name: String)]
    @Binding var selection: String?

    var body: some View {
        Menu {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { selection = nil }
            } label: {
                if selection == nil {
                    Label("all classes", systemImage: "checkmark")
                } else {
                    Text("all classes")
                }
            }
            Divider()
            ForEach(courses, id: \.key) { course in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { selection = course.key }
                } label: {
                    if selection == course.key {
                        Label(course.name, systemImage: "checkmark")
                    } else {
                        Text(course.name)
                    }
                }
            }
        } label: {
            DashCircleIcon(
                systemName: selection == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",
                foreground: Color.smoothCobalt,
                fill: Color.smoothCobalt.opacity(selection == nil ? 0.16 : 0.28)
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(selection.map { "filtered to \($0)" } ?? "filter by class")
    }
}

/// Shown under the control row only while a class filter is on.
struct ClassFilterChip: View {
    let name: String
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 6) {
                Text(name.uppercased())
                    .font(.lhfMono(10, weight: .semibold))
                    .tracking(1)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Color.smoothCobalt)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.smoothCobalt.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("clear \(name) filter")
    }
}

/// The 38pt circle every button on the control row shares.
struct DashCircleIcon: View {
    let systemName: String
    let foreground: Color
    let fill: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 38, height: 38)
            .background(Circle().fill(fill))
            .contentShape(Circle())
    }
}

/// The "open in place" row prev uses for "earlier this semester": a title,
/// a count, a chevron that turns.
struct DisclosureRow: View {
    let title: String
    let count: Int
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button {
            lhfHapticLight()
            action()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.lhfMono(11, weight: .semibold))
                    .tracking(0.4)
                Text("\(count)")
                    .font(.lhfMono(11, weight: .semibold))
                    .foregroundStyle(Color.smoothMuted)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .foregroundStyle(Color.smoothInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.smoothInk.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityHint(isOpen ? "hides them" : "shows them")
    }
}

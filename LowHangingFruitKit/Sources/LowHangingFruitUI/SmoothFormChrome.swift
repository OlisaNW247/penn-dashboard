import SwiftUI

/// A compact identity block for the two utility pages. It uses the same hard
/// ink line and vivid color family as assignment cards, but stays flatter and
/// quieter so controls remain the focus.
struct SmoothFormHeader: View {
    let title: String
    let accent: Color
    let spark: Color

    var body: some View {
        HStack(spacing: 16) {
            // One line always: "Announcements" at 32pt beside the 78pt
            // shape cluster wrapped onto two lines on a phone.
            Text(title)
                .font(.lhfSerif(32))
                .foregroundStyle(Color.smoothInk)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)

            Spacer(minLength: 12)

            SmoothFormShapes(accent: accent, spark: spark)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SmoothSectionHeader: View {
    let title: String
    let accent: Color

    init(_ title: String, accent: Color) {
        self.title = title
        self.accent = accent
    }

    var body: some View {
        Text(title)
            .font(.lhfMono(11, weight: .semibold))
            .tracking(0.45)
            .foregroundStyle(accent)
            .textCase(nil)
    }
}

private struct SmoothFormChrome: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        content
            .tint(accent)
            .environment(\.defaultMinListRowHeight, 48)
            .listRowSeparatorTint(Color.smoothRule.opacity(0.65))
#if os(iOS)
            .listSectionSpacing(.custom(18))
#endif
    }
}

extension View {
    func smoothFormChrome(accent: Color) -> some View {
        modifier(SmoothFormChrome(accent: accent))
    }

    func smoothSectionBackground(_ color: Color) -> some View {
        listRowBackground(color.opacity(0.13))
    }
}

/// The four-shape cluster beside a page title (Profile, the approve sheet,
/// the Sweeper) and above ask's greeting.
///
/// **On ask it hovers (2026-11-11, Marco: "when you open the AI ... the shapes
/// could be hovering in a cool way").** With `hovers` true each shape drifts a
/// few points on its own slow sine loop (`SmoothShapeHover`), driven by a
/// `TimelineView(.animation)` local to this view, so only these four shapes
/// re-render per frame and nothing publishes into `AppState`. The caller
/// passes `hovers: false` while the student types and under Reduce Motion
/// (AssistantView); every other page leaves the default, `false`, and stays
/// exactly as drawn before. The wrong fix is a `Timer` writing a phase into
/// shared state: every view reading that state would re-evaluate 30 times a
/// second (the badge freeze trap in CLAUDE.md).
struct SmoothFormShapes: View {
    let accent: Color
    let spark: Color
    var hovers: Bool = false

    var body: some View {
        Group {
            if hovers {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
                    shapes(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                shapes(at: nil)
            }
        }
        .frame(width: 78, height: 72)
        .accessibilityHidden(true)
    }

    private func shapes(at t: TimeInterval?) -> some View {
        func drift(_ i: Int) -> SmoothShapeHover.Drift {
            t.map { SmoothShapeHover.drift(shape: i, at: $0) } ?? .still
        }
        return ZStack {
            Circle()
                .fill(spark)
                .frame(width: 22, height: 22)
                .offset(x: -24 + drift(0).x, y: 20 + drift(0).y)
            Circle()
                .fill(Color.smoothLemon)
                .frame(width: 12, height: 12)
                .offset(x: 26 + drift(1).x, y: -21 + drift(1).y)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(0.22))
                .frame(width: 58, height: 42)
                .rotationEffect(.degrees(-8 + drift(2).degrees))
                .offset(x: drift(2).x, y: drift(2).y)
            Capsule()
                .fill(accent)
                .frame(width: 42, height: 13)
                .rotationEffect(.degrees(18 + drift(3).degrees))
                .offset(x: drift(3).x, y: drift(3).y)
        }
    }
}

/// Where each hovering shape is at a moment: pure, so the loop's bounds are
/// tested without a view. Each shape has its own period (3 to 6 s), amplitude
/// (3 to 6 pt) and phase, so the four never move in step; the tilt is at most
/// 2 degrees.
enum SmoothShapeHover {
    struct Drift: Equatable {
        var x: Double, y: Double, degrees: Double
        static let still = Drift(x: 0, y: 0, degrees: 0)
    }

    /// (period s, amplitude pt, phase rad, tilt degrees) per shape.
    static let loops: [(period: Double, amplitude: Double, phase: Double, tilt: Double)] = [
        (4.2, 5, 0.0, 0),
        (3.1, 3, 1.7, 0),
        (5.6, 4, 3.1, 1.5),
        (4.9, 6, 4.4, 2),
    ]

    static func drift(shape index: Int, at t: TimeInterval) -> Drift {
        guard loops.indices.contains(index) else { return .still }
        let l = loops[index]
        let angle = 2 * Double.pi * t / l.period + l.phase
        // A slow ellipse: y moves the full amplitude, x a little over half,
        // on a shifted angle, so the path is not a straight bob.
        return Drift(x: l.amplitude * 0.6 * cos(angle * 0.5 + l.phase),
                     y: l.amplitude * sin(angle),
                     degrees: l.tilt * sin(angle + 0.9))
    }
}

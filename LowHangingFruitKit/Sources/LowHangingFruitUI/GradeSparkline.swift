import SwiftUI
import LowHangingFruitKit

/// A tiny hand-rolled trend line for a course card — no chart dependency,
/// same spirit as `ProgressRingView`. Points are index-spaced rather than
/// date-true: this is a trend glyph, not an axis chart, and even spacing
/// keeps a weekly-cadence course readable instead of bunching early points
/// and trailing a long flat tail to today.
struct GradeSparkline: View {
    let points: [GradeEngine.TrajectoryPoint]
    /// Endpoint dot tint (direction is also carried by the delta chip's
    /// arrow + number, so color is never the only signal).
    let endpointColor: Color

    var body: some View {
        GeometryReader { geo in
            let coords = Self.coordinates(points.map(\.percent), in: geo.size)
            if let last = coords.last {
                Path { path in
                    path.addLines(coords)
                }
                .stroke(
                    Color.v2DateText,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
                Circle()
                    .fill(endpointColor)
                    .frame(width: 5, height: 5)
                    .position(last)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let first = points.first, let last = points.last else { return "Grade trend" }
        return "Grade over the term: from \(Int(first.percent.rounded())) to \(Int(last.percent.rounded())) percent"
    }

    /// Maps values into the frame with a small inset (room for the endpoint
    /// dot). The vertical domain is padded to at least 2 percentage points so
    /// a near-flat course draws as a calm centered line instead of noise
    /// stretched to full height.
    static func coordinates(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, let lo = values.min(), let hi = values.max() else { return [] }
        let inset: CGFloat = 3
        let span = max(hi - lo, 2)
        let bottom = (hi + lo) / 2 - span / 2
        let width = size.width - inset * 2
        let height = size.height - inset * 2
        return values.enumerated().map { index, value in
            CGPoint(
                x: inset + width * CGFloat(index) / CGFloat(values.count - 1),
                y: inset + height * (1 - CGFloat((value - bottom) / span))
            )
        }
    }
}

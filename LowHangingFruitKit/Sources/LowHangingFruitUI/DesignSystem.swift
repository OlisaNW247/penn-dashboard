import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: – Colors

extension Color {
    static let lhfBg       = Color(hex: 0xE6E4CE)
    static let lhfEggshell = Color(hex: 0xE6E4CE)
    static let lhfGraphite = Color(hex: 0x30323D)
    static let lhfPast     = Color(hex: 0xA4031F)  // Ruby Red — overdue
    static let lhfUrgent   = Color(hex: 0xE28413)  // Amber Earth — <24 h
    static let lhfUpcoming = Color(hex: 0x3A6EA5)  // Cornflower Ocean — <3 days
    static let lhfFuture   = Color(hex: 0x439A86)  // Seagrass — 4+ days

    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >>  8) & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: – Fonts
//
// To enable custom fonts, place the .ttf files here:
//   Sources/LowHangingFruitApp/Resources/Fonts/
//     Geist-Regular.ttf
//     Geist-Medium.ttf
//     Geist-SemiBold.ttf
//     InstrumentSerif-Regular.ttf
//
// Then add to Package.swift LowHangingFruitApp target:
//   resources: [.process("Resources")]
//
// Until then, SwiftUI silently falls back to the system font.

extension Font {
    static func geist(_ size: CGFloat, weight: Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black: name = "Geist-SemiBold"
        case .medium:                          name = "Geist-Medium"
        default:                               name = "Geist-Regular"
        }
        return .custom(name, size: size)
    }

    static func instrumentSerif(_ size: CGFloat) -> Font {
        .custom("InstrumentSerif-Regular", size: size)
    }
}

// MARK: – Urgency

enum Urgency {
    case past, urgent, upcoming, future

    init(dueAt: Date?, now: Date = Date()) {
        guard let due = dueAt else { self = .future; return }
        let diff = due.timeIntervalSince(now)
        if diff <= 0                  { self = .past }
        else if diff < 86_400         { self = .urgent }
        else if diff < 86_400 * 3    { self = .upcoming }
        else                          { self = .future }
    }

    var cardColor: Color {
        switch self {
        case .past:     return .lhfPast
        case .urgent:   return .lhfUrgent
        case .upcoming: return .lhfUpcoming
        case .future:   return .lhfFuture
        }
    }

    /// Ruby Red always pulses; Amber pulses only in the final hour.
    func shouldPulse(dueAt: Date?, now: Date = Date()) -> Bool {
        switch self {
        case .past:   return true
        case .urgent:
            guard let due = dueAt else { return false }
            return due.timeIntervalSince(now) < 3600
        default: return false
        }
    }
}

// MARK: – Due-date formatting (no weekday names)

func formatDue(_ dueAt: Date?, now: Date = Date()) -> String {
    guard let due = dueAt else { return "No due date" }
    let diff = due.timeIntervalSince(now)

    if diff <= 0 {
        let elapsed = -diff
        if elapsed < 3600 {
            let m = max(1, Int(elapsed / 60)); return "\(m)m late"
        }
        let h = Int(elapsed / 3600)
        let d = Int(elapsed / 86400)
        if d < 1 { return "\(h)h late" }
        return "\(d) day\(d == 1 ? "" : "s") late"
    }

    if diff < 3600  { let m = max(1, Int(diff / 60));  return "\(m)m left" }
    if diff < 86400 { let h = Int(diff / 3600);         return "\(h)h left" }

    let days = Int(diff / 86400)
    if days == 1 { return "Due tomorrow" }
    return "Due in \(days) days"
}

// MARK: – Haptics (iOS only, no-op on macOS)

func triggerHaptic(_ urgency: Urgency) {
#if os(iOS)
    let style: UIImpactFeedbackGenerator.FeedbackStyle
    switch urgency {
    case .past:   style = .heavy
    case .urgent: style = .medium
    default:      style = .light
    }
    UIImpactFeedbackGenerator(style: style).impactOccurred()
#endif
}

// MARK: – Checkmark shape

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to:    CGPoint(x: rect.minX + rect.width * 0.09, y: rect.midY + rect.height * 0.08))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.37, y: rect.maxY - rect.height * 0.18))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.minY + rect.height * 0.20))
        return p
    }
}

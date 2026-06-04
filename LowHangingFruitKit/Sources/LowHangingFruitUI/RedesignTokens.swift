import SwiftUI
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: – Palette (UI redesign v2)
//
// A warm-greige, paper-like system. Cards are white with a colored "spine"
// on the left whose color encodes due-date urgency. All values are taken
// straight from the design spec. `Color(hex:)` is defined in DesignSystem.swift.

extension Color {
    static let v2Bg          = Color(hex: 0xF4F1EC)  // warm greige background
    static let v2Card        = Color(hex: 0xFFFFFF)  // active card surface
    static let v2CardShadow  = Color(hex: 0x786E5A)  // soft shadow tint (used at ~6%)
    static let v2Ink         = Color(hex: 0x211F1B)  // primary text / titles
    static let v2DateText    = Color(hex: 0x5C574E)  // header date / serif footer
    static let v2CourseCode  = Color(hex: 0xA39C8E)  // course code on active cards

    // Urgency — spines (hot → cool: overdue → today → soon → later)
    static let v2SpineRed    = Color(hex: 0xC8443A)  // overdue
    static let v2SpineAmber  = Color(hex: 0xD98C2B)  // due <24h
    static let v2SpineBlue   = Color(hex: 0x3A6EA5)  // due 1–3 days (upcoming)
    static let v2SpineGreen  = Color(hex: 0x2E7D6B)  // due 4+ days / later

    // Urgency — due text (slightly darker than the spine)
    static let v2DueRed      = Color(hex: 0xC8443A)
    static let v2DueAmber    = Color(hex: 0xC2861A)
    static let v2DueBlue     = Color(hex: 0x2F5C8A)
    static let v2DueGreen    = Color(hex: 0x2E7D6B)

    // Ring
    static let v2RingTrack   = Color(hex: 0xE5DDCE)
    static let v2RingSub     = Color(hex: 0x928C80)  // "done" caption under ring number

    // Segmented toggle
    static let v2ToggleBg       = Color(hex: 0xE9E3D8)
    static let v2ToggleActive   = Color(hex: 0x211F1B)
    static let v2ToggleActiveTx = Color(hex: 0xF4F1EC)
    static let v2ToggleInactive = Color(hex: 0x928C80)

    // Section headers
    static let v2Divider       = Color(hex: 0xE2DBCE)
    static let v2SectionMuted  = Color(hex: 0x7A6F50)  // TODAY / REST OF WEEK / LATER labels
    static let v2SectionCount  = Color(hex: 0xB0A892)  // per-section count

    // Done (archived) cards
    static let v2DoneCard    = Color(hex: 0xF0EDE6)
    static let v2DoneSpine   = Color(hex: 0xB6B0A2)
    static let v2DoneTitle   = Color(hex: 0x8A8478)
    static let v2DoneCourse  = Color(hex: 0xAEA899)
}

// MARK: – Fonts (Instrument Serif display, Geist body)
//
// Prefers the bundled custom faces if present, otherwise falls back to the
// system serif / sans designs so the serif↔sans distinction survives even
// when the .ttf files aren't bundled.

private func fontIsAvailable(_ name: String) -> Bool {
#if canImport(UIKit)
    return UIFont(name: name, size: 12) != nil
#elseif canImport(AppKit)
    return NSFont(name: name, size: 12) != nil
#else
    return false
#endif
}

extension Font {
    /// Instrument Serif (display) with a system-serif fallback.
    static func lhfSerif(_ size: CGFloat) -> Font {
        fontIsAvailable("InstrumentSerif-Regular")
            ? .custom("InstrumentSerif-Regular", size: size)
            : .system(size: size, weight: .regular, design: .serif)
    }

    /// Geist (body) with a system-sans fallback. Keeps weights.
    static func lhfSans(_ size: CGFloat, weight: Weight = .regular) -> Font {
        let custom: String
        switch weight {
        case .semibold, .bold, .heavy, .black: custom = "Geist-SemiBold"
        case .medium:                          custom = "Geist-Medium"
        default:                               custom = "Geist-Regular"
        }
        return fontIsAvailable(custom)
            ? .custom(custom, size: size)
            : .system(size: size, weight: weight, design: .default)
    }
}

// MARK: – Bundled images

/// Loads an image bundled in the app target's Resources (cross-platform).
func bundledImage(_ name: String, ext: String) -> Image? {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext),
          let data = try? Data(contentsOf: url) else { return nil }
#if canImport(UIKit)
    guard let img = UIImage(data: data) else { return nil }
    return Image(uiImage: img)
#elseif canImport(AppKit)
    guard let img = NSImage(data: data) else { return nil }
    return Image(nsImage: img)
#else
    return nil
#endif
}

// MARK: – Due-date urgency state (reads the model, never mutates it)

/// Four-state urgency derived purely from an effective due date. This is a
/// presentation concept layered on top of `Assignment`; the model is untouched.
enum DueState {
    case overdue        // past due
    case today          // due within the next 24h
    case soon           // due 1–3 days out
    case later          // due 4+ days out, or no due date

    init(due: Date?, now: Date = Date()) {
        guard let due else { self = .later; return }
        let s = due.timeIntervalSince(now)
        if s < 0                  { self = .overdue }
        else if s < 86_400        { self = .today }
        else if s < 86_400 * 4    { self = .soon }
        else                      { self = .later }
    }

    var spineColor: Color {
        switch self {
        case .overdue: return .v2SpineRed
        case .today:   return .v2SpineAmber
        case .soon:    return .v2SpineBlue
        case .later:   return .v2SpineGreen
        }
    }

    var dueTextColor: Color {
        switch self {
        case .overdue: return .v2DueRed
        case .today:   return .v2DueAmber
        case .soon:    return .v2DueBlue
        case .later:   return .v2DueGreen
        }
    }
}

/// Compact, weekday-free due text: "2 days late", "5h left", "in 3 days".
/// Day counts are calendar-day differences (not raw 24h chunks), so an item
/// due "in 2 days" reads that way regardless of the time of day.
func dueText(_ due: Date?, now: Date = Date()) -> String {
    guard let due else { return "no due date" }
    let s = due.timeIntervalSince(now)
    let cal = Calendar.current

    if s < 0 {
        let late = -s
        if late < 86_400 {
            let h = max(1, Int(late / 3600))
            return "\(h)h late"
        }
        let d = cal.dateComponents([.day], from: cal.startOfDay(for: due),
                                   to: cal.startOfDay(for: now)).day ?? Int(late / 86_400)
        return "\(max(1, d)) day\(d == 1 ? "" : "s") late"
    }

    if s < 86_400 {
        let h = max(1, Int(s / 3600))
        return "\(h)h left"
    }

    let d = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                               to: cal.startOfDay(for: due)).day ?? Int(s / 86_400)
    return "in \(max(1, d)) day\(d == 1 ? "" : "s")"
}

// MARK: – Haptics (iOS only, no-op on macOS)

func lhfHaptic(for state: DueState) {
#if os(iOS)
    let style: UIImpactFeedbackGenerator.FeedbackStyle
    switch state {
    case .overdue:        style = .heavy
    case .today:          style = .medium
    case .soon, .later:   style = .light
    }
    UIImpactFeedbackGenerator(style: style).impactOccurred()
#endif
}

func lhfHapticLight() {
#if os(iOS)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
}

import SwiftUI
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: – Palette (UI redesign v2.5 — white + dark)
//
// A clean white/neutral system with a designed dark mode. Cards carry a
// colored "spine" whose color encodes due-date urgency. Every token is a
// (light, dark) pair via `Color(light:dark:)` (DesignSystem.swift), so the
// whole UI follows the system appearance. The four urgency hues are the app's
// identity: kept as-is on white, brightened on dark so they still pop.

extension Color {
    static let v2Bg          = Color(light: 0xFAFAFA, dark: 0x1A1A1D)  // near-white / dark neutral canvas
    static let v2Card        = Color(light: 0xFFFFFF, dark: 0x242428)  // active card surface
    static let v2CardShadow  = Color(light: 0x5A5A60, dark: 0x000000)  // soft shadow tint (used at ~6%)
    static let v2Ink         = Color(light: 0x1C1C1E, dark: 0xF2F2F4)  // primary text / titles
    static let v2DateText    = Color(light: 0x55555A, dark: 0xB0B0B6)  // header date / serif footer
    static let v2CourseCode  = Color(light: 0x9A9AA0, dark: 0x7E7E86)  // course code on active cards

    // Urgency — spines (hot → cool: overdue → today → soon → later)
    static let v2SpineRed    = Color(light: 0xC8443A, dark: 0xE5675C)  // overdue
    static let v2SpineAmber  = Color(light: 0xD98C2B, dark: 0xE8A34A)  // due <24h
    static let v2SpineBlue   = Color(light: 0x3A6EA5, dark: 0x6B9BD1)  // due 1–3 days (upcoming)
    static let v2SpineGreen  = Color(light: 0x2E7D6B, dark: 0x4CA891)  // due 4+ days / later

    // Urgency — due text (darkened on white for legibility; the bright spine on dark)
    static let v2DueRed      = Color(light: 0xC8443A, dark: 0xE5675C)
    static let v2DueAmber    = Color(light: 0xA66E12, dark: 0xE8A34A)
    static let v2DueBlue     = Color(light: 0x2F5C8A, dark: 0x6B9BD1)
    static let v2DueGreen    = Color(light: 0x2E7D6B, dark: 0x4CA891)

    // Ring
    static let v2RingTrack   = Color(light: 0xECECEE, dark: 0x303036)
    static let v2RingSub     = Color(light: 0x9A9AA0, dark: 0x8A8A90)  // "done" caption under ring number

    // Segmented toggle
    static let v2ToggleBg       = Color(light: 0xF0F0F2, dark: 0x2A2A2F)
    static let v2ToggleActive   = Color(light: 0x1C1C1E, dark: 0xF2F2F4)
    static let v2ToggleActiveTx = Color(light: 0xFFFFFF, dark: 0x1A1A1D)
    static let v2ToggleInactive = Color(light: 0x9A9AA0, dark: 0x8A8A90)

    // Section headers
    static let v2Divider       = Color(light: 0xECECEE, dark: 0x2E2E34)
    static let v2SectionMuted  = Color(light: 0x7A7A80, dark: 0x9A9AA2)  // TODAY / REST OF WEEK / LATER labels
    static let v2SectionCount  = Color(light: 0xB8B8BE, dark: 0x66666E)  // per-section count

    // Done (archived) cards
    static let v2DoneCard    = Color(light: 0xF4F4F5, dark: 0x202024)
    static let v2DoneSpine   = Color(light: 0xC4C4C8, dark: 0x4A4A52)
    static let v2DoneTitle   = Color(light: 0x8A8A90, dark: 0x7E7E86)
    static let v2DoneCourse  = Color(light: 0xB0B0B6, dark: 0x5E5E66)
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

    /// A colored dot that carries the urgency tier into places that can't render
    /// SwiftUI color — notably local notifications, whose text the OS styles.
    /// Matches the card spine palette (red / amber / blue / green).
    var urgencyEmoji: String {
        switch self {
        case .overdue: return "🔴"
        case .today:   return "🟠"
        case .soon:    return "🔵"
        case .later:   return "🟢"
        }
    }

    /// The two most-urgent tiers ask iOS to break through Focus / Do Not Disturb.
    var isTimeSensitive: Bool {
        switch self {
        case .overdue, .today: return true
        case .soon, .later:    return false
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

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
//
// Every token below is a *dynamic* color (see `Color.dynamic(light:dark:)`):
// it resolves per interface style, so anything that reads e.g. `.v2Bg` just
// works in both Light and Dark without touching call sites. Light values are
// the original, unchanged palette (zero visual diff for existing users);
// dark values are a tasteful inversion — near-black warm charcoal surfaces,
// warm off-white text, and the same four urgency hues brightened/desaturated
// slightly for legibility on a dark background.

extension Color {
    static let v2Bg          = Color.dynamic(light: 0xF4F1EC, dark: 0x1C1A17)  // warm greige background
    static let v2Card        = Color.dynamic(light: 0xFFFFFF, dark: 0x26241F)  // active card surface
    static let v2CardShadow  = Color.dynamic(light: 0x786E5A, dark: 0x000000)  // soft shadow tint (used at ~6%)
    static let v2Ink         = Color.dynamic(light: 0x211F1B, dark: 0xEFECE6)  // primary text / titles
    static let v2DateText    = Color.dynamic(light: 0x5C574E, dark: 0xB9B3A8)  // header date / serif footer
    static let v2CourseCode  = Color.dynamic(light: 0xA39C8E, dark: 0x9A9384)  // course code on active cards

    // Urgency — spines (hot → cool: overdue → today → soon → later)
    static let v2SpineRed    = Color.dynamic(light: 0xC8443A, dark: 0xE0574C)  // overdue
    static let v2SpineAmber  = Color.dynamic(light: 0xD98C2B, dark: 0xE6A248)  // due <24h
    static let v2SpineBlue   = Color.dynamic(light: 0x3A6EA5, dark: 0x5B8FC7)  // due 1–3 days (upcoming)
    static let v2SpineGreen  = Color.dynamic(light: 0x2E7D6B, dark: 0x4FA08D)  // due 4+ days / later
    /// Provenance accent, not an urgency: marks numbers that came from the
    /// user's own syllabus. Deliberately outside the hot→cool urgency ramp so
    /// a syllabus badge can't be misread as a deadline signal.
    static let v2SpinePurple = Color.dynamic(light: 0x6B5B95, dark: 0x9B8BC4)

    // Urgency — due text (slightly darker than the spine)
    static let v2DueRed      = Color.dynamic(light: 0xC8443A, dark: 0xE0574C)
    static let v2DueAmber    = Color.dynamic(light: 0xC2861A, dark: 0xD9A13F)
    static let v2DueBlue     = Color.dynamic(light: 0x2F5C8A, dark: 0x5B8FC7)
    static let v2DueGreen    = Color.dynamic(light: 0x2E7D6B, dark: 0x4FA08D)

    // Ring
    static let v2RingTrack   = Color.dynamic(light: 0xE5DDCE, dark: 0x35322B)
    static let v2RingSub     = Color.dynamic(light: 0x928C80, dark: 0x9A9384)  // "done" caption under ring number

    // Segmented toggle
    static let v2ToggleBg       = Color.dynamic(light: 0xE9E3D8, dark: 0x2E2B25)
    static let v2ToggleActive   = Color.dynamic(light: 0x211F1B, dark: 0xEFECE6)
    static let v2ToggleActiveTx = Color.dynamic(light: 0xF4F1EC, dark: 0x1C1A17)
    static let v2ToggleInactive = Color.dynamic(light: 0x928C80, dark: 0x8B8477)

    // Section headers
    static let v2Divider       = Color.dynamic(light: 0xE2DBCE, dark: 0x322F28)
    static let v2SectionMuted  = Color.dynamic(light: 0x7A6F50, dark: 0xA79C7E)  // TODAY / REST OF WEEK / LATER labels
    static let v2SectionCount  = Color.dynamic(light: 0xB0A892, dark: 0x7D7666)  // per-section count

    // Done (archived) cards
    static let v2DoneCard    = Color.dynamic(light: 0xF0EDE6, dark: 0x201E1A)
    static let v2DoneSpine   = Color.dynamic(light: 0xB6B0A2, dark: 0x4A473E)
    static let v2DoneTitle   = Color.dynamic(light: 0x8A8478, dark: 0x6E6A5D)
    static let v2DoneCourse  = Color.dynamic(light: 0xAEA899, dark: 0x7A755F)

    /// A color that resolves to `light` or `dark` hex based on the active
    /// interface style, wherever it's drawn. Backed by a `UIColor`/`NSColor`
    /// dynamic provider so it keys off the trait collection / appearance in
    /// effect at draw time — which `.preferredColorScheme` sets for the whole
    /// view hierarchy it's applied to — with no environment threading needed
    /// at each call site.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
#if canImport(UIKit)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light))
        })
#elseif canImport(AppKit)
        return Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
#else
        return Color(hex: light)
#endif
    }
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

/// Maps one of the design's literal point sizes onto the closest system text
/// style, which is what Dynamic Type scales against. The design was drawn in
/// fixed points, so rather than restyle every call site we scale each size
/// *relative to* the style it most resembles — a 12pt caption and a 32pt title
/// then grow at the rates users expect, and the visual hierarchy is preserved
/// at every setting.
private func lhfTextStyle(for size: CGFloat) -> Font.TextStyle {
    switch size {
    case ..<12:    return .caption2
    case ..<13:    return .caption
    case ..<15:    return .footnote
    case ..<16:    return .subheadline
    case ..<17:    return .callout
    case ..<20:    return .body
    case ..<22:    return .title3
    case ..<28:    return .title2
    case ..<34:    return .title
    default:       return .largeTitle
    }
}

/// Scales a design point size for the user's current Dynamic Type setting,
/// keeping the exact base size rather than snapping to the text style's own.
/// AppKit has no equivalent metrics API, so macOS keeps the fixed size.
private func lhfScaled(_ size: CGFloat) -> CGFloat {
#if canImport(UIKit)
    return UIFontMetrics(forTextStyle: uiTextStyle(for: lhfTextStyle(for: size)))
        .scaledValue(for: size)
#else
    return size
#endif
}

#if canImport(UIKit)
private func uiTextStyle(for style: Font.TextStyle) -> UIFont.TextStyle {
    switch style {
    case .largeTitle: return .largeTitle
    case .title:      return .title1
    case .title2:     return .title2
    case .title3:     return .title3
    case .headline:   return .headline
    case .callout:    return .callout
    case .subheadline: return .subheadline
    case .footnote:   return .footnote
    case .caption:    return .caption1
    case .caption2:   return .caption2
    default:          return .body
    }
}
#endif

extension Font {
    /// Instrument Serif (display) with a system-serif fallback. Both paths
    /// scale with the user's text size.
    static func lhfSerif(_ size: CGFloat) -> Font {
        fontIsAvailable("InstrumentSerif-Regular")
            ? .custom("InstrumentSerif-Regular", size: size, relativeTo: lhfTextStyle(for: size))
            : .system(size: lhfScaled(size), weight: .regular, design: .serif)
    }

    /// Geist (body) with a system-sans fallback. Keeps weights, and scales with
    /// the user's text size.
    ///
    /// The fallback branch is the one that actually ships today — no Geist or
    /// Instrument Serif files are bundled or registered, so `fontIsAvailable`
    /// is always false. That is exactly why this needed fixing: `.system(size:)`
    /// is a fixed point size and ignores Dynamic Type entirely, so every font
    /// in the app was frozen at its design size no matter what the user chose
    /// in Accessibility settings.
    static func lhfSans(_ size: CGFloat, weight: Weight = .regular) -> Font {
        let custom: String
        switch weight {
        case .semibold, .bold, .heavy, .black: custom = "Geist-SemiBold"
        case .medium:                          custom = "Geist-Medium"
        default:                               custom = "Geist-Regular"
        }
        return fontIsAvailable(custom)
            ? .custom(custom, size: size, relativeTo: lhfTextStyle(for: size))
            : .system(size: lhfScaled(size), weight: weight, design: .default)
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

import SwiftUI
import LowHangingFruitKit
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: – Smooth palette
//
// The dashboard's color is semantic: every assignment is filled from a
// warm-to-cool deadline ramp. Neutral app chrome stays on white so color never
// competes with urgency. The v2 aliases keep the rest of the app on the
// same family without changing any feature wiring.

extension Color {
    static let smoothPaper    = Color(hex: 0xFFFFFF)
    static let smoothSurface  = Color(hex: 0xF2E5C9)
    static let smoothRule     = Color(hex: 0xD9C9A6)
    static let smoothInk      = Color(hex: 0x1B1714)
    static let smoothMuted    = Color(hex: 0x7C7060)
    static let smoothTomato   = Color(hex: 0xF07256)
    static let smoothMarigold = Color(hex: 0xF7A844)
    static let smoothLemon    = Color(hex: 0xF5D353)
    static let smoothTeal     = Color(hex: 0x40B3A5)
    static let smoothCobalt   = Color(hex: 0x699AE7)
    static let smoothGrape    = Color(hex: 0xAF85F0)

    // Dark companions for text placed on each pastel urgency field.
    static let smoothTomatoInk   = Color.dynamic(light: 0xB63B23, dark: 0xF59A85)
    static let smoothMarigoldInk = Color.dynamic(light: 0x985700, dark: 0xFBCB75)
    static let smoothLemonInk    = Color.dynamic(light: 0x746400, dark: 0xF9E889)
    static let smoothTealInk     = Color.dynamic(light: 0x176D65, dark: 0x76D4C9)
    static let smoothCobaltInk   = Color.dynamic(light: 0x345EA8, dark: 0xA8C4F5)
    static let smoothGrapeInk    = Color.dynamic(light: 0x7044A6, dark: 0xD0B2F7)

    static let v2Bg          = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1A17)
    static let v2Card        = Color.dynamic(light: 0xFFFFFF, dark: 0x26241F)
    static let v2CardShadow  = Color.dynamic(light: 0x1B1714, dark: 0x000000)
    static let v2Ink         = Color.dynamic(light: 0x1B1714, dark: 0xFBF2DF)
    static let v2DateText    = Color.dynamic(light: 0x7C7060, dark: 0xD9C9A6)
    static let v2CourseCode  = Color.dynamic(light: 0x7C7060, dark: 0xD9C9A6)

    // Urgency — spines (hot → cool: overdue → today → soon → later)
    static let v2SpineRed    = Color.smoothTomato
    static let v2SpineAmber  = Color.smoothMarigold
    static let v2SpineBlue   = Color.smoothCobalt
    static let v2SpineGreen  = Color.smoothTeal
    /// Provenance accent, not an urgency: marks numbers that came from the
    /// user's own syllabus. Deliberately outside the hot→cool urgency ramp so
    /// a syllabus badge can't be misread as a deadline signal.
    static let v2SpinePurple = Color.smoothGrape

    // Urgency — due text (slightly darker than the spine)
    static let v2DueRed      = Color.smoothTomato
    static let v2DueAmber    = Color.smoothMarigold
    static let v2DueBlue     = Color.smoothCobalt
    static let v2DueGreen    = Color.smoothTeal

    // Ring
    static let v2RingTrack   = Color.dynamic(light: 0xD9C9A6, dark: 0x35322B)
    static let v2RingSub     = Color.dynamic(light: 0x7C7060, dark: 0x9A9384)

    // Segmented toggle
    static let v2ToggleBg       = Color.dynamic(light: 0xF2E5C9, dark: 0x2E2B25)
    static let v2ToggleActive   = Color.dynamic(light: 0x1B1714, dark: 0xFBF2DF)
    static let v2ToggleActiveTx = Color.dynamic(light: 0xFFFFFF, dark: 0x1B1714)
    static let v2ToggleInactive = Color.dynamic(light: 0x1B1714, dark: 0xD9C9A6)

    // Section headers
    static let v2Divider       = Color.dynamic(light: 0xD9C9A6, dark: 0x322F28)
    static let v2SectionMuted  = Color.dynamic(light: 0x1B1714, dark: 0xFBF2DF)
    static let v2SectionCount  = Color.dynamic(light: 0x7C7060, dark: 0xD9C9A6)

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

// MARK: – Smooth fonts

private enum SmoothFontRegistry {
    static let registration: Void = {
        for (name, ext) in [
            ("Satoshi-Variable", "ttf"),
            ("Satoshi-VariableItalic", "ttf"),
            ("Roobert-SemiBold", "otf"),
            ("Roobert-SemiBoldItalic", "otf"),
            ("Inter", "ttf"),
            ("FamiljenGrotesk-Variable", "ttf"),
            ("SpaceMono-Regular", "ttf"),
            ("SpaceMono-Bold", "ttf"),
        ] {
            guard let url = Bundle.module.url(forResource: name, withExtension: ext) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func ensureRegistered() { _ = registration }
}

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
    /// Satoshi for every primary title, including assignment and screen titles.
    /// Kept under the existing name so screen behavior stays unchanged.
    static func lhfSerif(_ size: CGFloat) -> Font {
        SmoothFontRegistry.ensureRegistered()
        return fontIsAvailable("SatoshiVariable-Bold")
            ? .custom("SatoshiVariable-Bold", size: size, relativeTo: lhfTextStyle(for: size))
            : .system(size: lhfScaled(size), weight: .bold, design: .default)
    }

    /// Roobert's italic display cut is reserved for the Smooth wordmark.
    static func lhfWordmark(_ size: CGFloat) -> Font {
        SmoothFontRegistry.ensureRegistered()
        return fontIsAvailable("RoobertTRIAL-SemiBoldItalic")
            ? .custom("RoobertTRIAL-SemiBoldItalic", size: size, relativeTo: lhfTextStyle(for: size))
            : lhfSerif(size).italic()
    }

    /// Upright Roobert for the weekday paired with the Smooth wordmark.
    static func lhfHeaderTitle(_ size: CGFloat) -> Font {
        SmoothFontRegistry.ensureRegistered()
        return fontIsAvailable("RoobertTRIAL-SemiBold")
            ? .custom("RoobertTRIAL-SemiBold", size: size, relativeTo: lhfTextStyle(for: size))
            : lhfSerif(size)
    }

    /// Satoshi is the primary interface face, with Inter as a safe fallback.
    static func lhfSans(_ size: CGFloat, weight: Weight = .regular) -> Font {
        SmoothFontRegistry.ensureRegistered()
        let satoshi: String
        let inter: String
        switch weight {
        case .bold, .heavy, .black:
            satoshi = "SatoshiVariable-Bold"
            inter = "Inter-Bold"
        case .semibold:
            satoshi = "SatoshiVariable-Medium"
            inter = "Inter-SemiBold"
        case .medium:
            satoshi = "SatoshiVariable-Medium"
            inter = "Inter-Medium"
        default:
            satoshi = "SatoshiVariable-Regular"
            inter = "Inter-Regular"
        }
        let custom = fontIsAvailable(satoshi) ? satoshi : inter
        return fontIsAvailable(custom)
            ? .custom(custom, size: size, relativeTo: lhfTextStyle(for: size))
            : .system(size: lhfScaled(size), weight: weight, design: .default)
    }

    /// Inter is reserved for supporting copy beneath the primary hierarchy.
    static func lhfSecondary(_ size: CGFloat, weight: Weight = .regular) -> Font {
        SmoothFontRegistry.ensureRegistered()
        let custom: String
        switch weight {
        case .bold, .heavy, .black: custom = "Inter-Bold"
        case .semibold:            custom = "Inter-SemiBold"
        case .medium:              custom = "Inter-Medium"
        default:                   custom = "Inter-Regular"
        }
        return fontIsAvailable(custom)
            ? .custom(custom, size: size, relativeTo: lhfTextStyle(for: size))
            : .system(size: lhfScaled(size), weight: weight, design: .default)
    }

    /// Familjen Grotesk is reserved for assignment names, giving the task list
    /// a sturdy, contemporary voice without changing the rest of Smooth's
    /// Satoshi / Inter / Space Mono hierarchy.
    static func lhfAssignmentTitle(_ size: CGFloat) -> Font {
        SmoothFontRegistry.ensureRegistered()
        return fontIsAvailable("FamiljenGroteskRoman-Medium")
            ? .custom("FamiljenGroteskRoman-Medium", size: size, relativeTo: lhfTextStyle(for: size))
            : lhfSans(size, weight: .medium)
    }

    /// Space Mono for course codes, deadlines, and other compact data.
    static func lhfMono(_ size: CGFloat, weight: Weight = .regular) -> Font {
        SmoothFontRegistry.ensureRegistered()
        let custom: String
        switch weight {
        case .semibold, .bold, .heavy, .black: custom = "SpaceMono-Bold"
        default:                              custom = "SpaceMono-Regular"
        }
        return fontIsAvailable(custom)
            ? .custom(custom, size: size, relativeTo: lhfTextStyle(for: size))
            : .system(size: lhfScaled(size), weight: weight, design: .monospaced)
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

/// The card accent is always derived from the effective due date. Green is
/// intentionally absent from Smooth: weekend and early-week work use
/// turquoise, then the ramp walks through cobalt and grape.
func smoothTaskAccent(_ due: Date?, now: Date = Date()) -> Color {
    guard let due else { return .smoothGrape }
    let seconds = due.timeIntervalSince(now)
    if seconds < 0 { return .smoothTomato }
    if seconds <= 7 * 3_600 { return .smoothMarigold }
    if seconds < 86_400 { return .smoothLemon }
    if seconds < 4 * 86_400 { return .smoothTeal }
    if seconds < 6 * 86_400 { return .smoothCobalt }
    return .smoothGrape
}

/// The darker partner used for course codes on the matching pastel field.
func smoothTaskTextAccent(_ due: Date?, now: Date = Date()) -> Color {
    guard let due else { return .smoothGrapeInk }
    let seconds = due.timeIntervalSince(now)
    if seconds < 0 { return .smoothTomatoInk }
    if seconds <= 7 * 3_600 { return .smoothMarigoldInk }
    if seconds < 86_400 { return .smoothLemonInk }
    if seconds < 4 * 86_400 { return .smoothTealInk }
    if seconds < 6 * 86_400 { return .smoothCobaltInk }
    return .smoothGrapeInk
}

/// A middle ground between the original solid cards and the first very pale
/// pass: still airy, but with enough hue to group deadlines at a glance.
func smoothTaskFill(_ due: Date?, now: Date = Date()) -> Color {
    smoothTaskAccent(due, now: now).opacity(0.26)
}

struct SmoothDueValue {
    let primary: String
    let secondary: String?
}

/// Compact two-line deadline value used on Smooth cards: `4d / late`, `5h`,
/// the weekday for the next five days, or a short date beyond that window.
/// Full dates remain available in expanded detail.
func smoothDueValue(_ due: Date?, now: Date = Date()) -> SmoothDueValue {
    guard let due else { return SmoothDueValue(primary: "—", secondary: "no date") }
    let seconds = due.timeIntervalSince(now)
    if seconds < 0 {
        let late = -seconds
        if late < 86_400 {
            return SmoothDueValue(primary: "\(max(1, Int(late / 3_600)))h", secondary: "late")
        }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: due),
            to: Calendar.current.startOfDay(for: now)
        ).day ?? Int(late / 86_400)
        return SmoothDueValue(primary: "\(max(1, days))d", secondary: "late")
    }
    if seconds < 86_400 {
        return SmoothDueValue(primary: "\(max(1, Int(seconds / 3_600)))h", secondary: nil)
    }
    if seconds <= 5 * 86_400 {
        return SmoothDueValue(
            primary: due.formatted(.dateTime.weekday(.abbreviated)),
            secondary: nil
        )
    }
    return SmoothDueValue(
        primary: due.formatted(.dateTime.month(.abbreviated).day()),
        secondary: nil
    )
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

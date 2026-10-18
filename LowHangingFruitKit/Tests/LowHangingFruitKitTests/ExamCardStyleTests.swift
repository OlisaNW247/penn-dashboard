import SwiftUI
import Testing
@testable import LowHangingFruitUI

/// The exam card's palette: inverted against the page in each mode, and
/// legible on its own fill.
///
/// The type colours are checked as arithmetic on `SmoothExamPalette` rather
/// than by resolving `Color`s, because a dynamic `Color` is opaque until a
/// platform draws it; one test below does resolve them, to make sure the
/// tokens really are built from the palette and not from a copy that drifted.
@Suite("Exam card style")
struct ExamCardStyleTests {

    // `Color.smoothPaper`'s two values: what the translucent fill sits on.
    private static let lightPaper: UInt32 = 0xFFFFFF
    private static let darkPaper: UInt32 = 0x0B1020

    private typealias RGB = (r: Double, g: Double, b: Double)

    private static func rgb(_ hex: UInt32) -> RGB {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// `shade` laid over an opaque `background`.
    private static func composite(_ shade: SmoothExamPalette.Shade, over background: RGB) -> RGB {
        let fg = rgb(shade.hex)
        return (
            shade.alpha * fg.r + (1 - shade.alpha) * background.r,
            shade.alpha * fg.g + (1 - shade.alpha) * background.g,
            shade.alpha * fg.b + (1 - shade.alpha) * background.b
        )
    }

    /// WCAG relative luminance.
    private static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// (fill as it appears over the page, the page) for each appearance.
    private static let light = (fill: composite(SmoothExamPalette.fill.light, over: rgb(lightPaper)), page: rgb(lightPaper))
    private static let dark = (fill: composite(SmoothExamPalette.fill.dark, over: rgb(darkPaper)), page: rgb(darkPaper))

    @Test("the fill is dark on paper and light after sunset")
    func fillInvertsThePage() {
        #expect(Self.luminance(Self.light.fill) < 0.1, "light mode card should read near-black")
        #expect(Self.luminance(Self.dark.fill) > 0.5, "dark mode card should read near-white")
        #expect(SmoothExamPalette.fill.light != SmoothExamPalette.fill.dark)
        // Inverse of the page, not just different from it.
        #expect(Self.luminance(Self.light.fill) < Self.luminance(Self.light.page))
        #expect(Self.luminance(Self.dark.fill) > Self.luminance(Self.dark.page))
    }

    @Test("the fill is slightly translucent, not clear and not solid")
    func fillIsTranslucent() {
        for shade in [SmoothExamPalette.fill.light, SmoothExamPalette.fill.dark] {
            #expect(shade.alpha > 0.8 && shade.alpha < 1)
        }
        #expect(SmoothExamPalette.fill.light.alpha == 0.86)
        #expect(SmoothExamPalette.fill.dark.alpha == 0.88)
    }

    @Test("text is white on the dark card and near-black on the pale one")
    func textInverts() {
        #expect(SmoothExamPalette.text.light.hex == 0xFFFFFF)
        #expect(Self.luminance(Self.rgb(SmoothExamPalette.text.dark.hex)) < 0.02)
        #expect(SmoothExamPalette.text.light != SmoothExamPalette.text.dark)
        #expect(SmoothExamPalette.secondaryText.light != SmoothExamPalette.secondaryText.dark)
        #expect(SmoothExamPalette.destructive.light != SmoothExamPalette.destructive.dark)
    }

    @Test("every text colour clears 4.5:1 on its fill, in both modes")
    func textIsLegible() {
        let tiers: [(String, SmoothExamPalette.Pair)] = [
            ("primary", SmoothExamPalette.text),
            ("secondary", SmoothExamPalette.secondaryText),
            ("destructive", SmoothExamPalette.destructive),
        ]
        for (name, pair) in tiers {
            let onLight = Self.composite(pair.light, over: Self.light.fill)
            let onDark = Self.composite(pair.dark, over: Self.dark.fill)
            let lightRatio = Self.contrast(onLight, Self.light.fill)
            let darkRatio = Self.contrast(onDark, Self.dark.fill)
            #expect(lightRatio >= 4.5, "\(name) in light mode is \(lightRatio):1")
            #expect(darkRatio >= 4.5, "\(name) in dark mode is \(darkRatio):1")
        }
    }

    @Test("secondary type is quieter than primary, in both modes")
    func secondaryIsQuieter() {
        let primaryLight = Self.contrast(Self.composite(SmoothExamPalette.text.light, over: Self.light.fill), Self.light.fill)
        let secondaryLight = Self.contrast(Self.composite(SmoothExamPalette.secondaryText.light, over: Self.light.fill), Self.light.fill)
        let primaryDark = Self.contrast(Self.composite(SmoothExamPalette.text.dark, over: Self.dark.fill), Self.dark.fill)
        let secondaryDark = Self.contrast(Self.composite(SmoothExamPalette.secondaryText.dark, over: Self.dark.fill), Self.dark.fill)
        #expect(secondaryLight < primaryLight)
        #expect(secondaryDark < primaryDark)
    }

    #if canImport(AppKit) || canImport(UIKit)
    // Resolving a SwiftUI `Color` asks the main thread for an appearance, and
    // blocks forever when called from the test runner's worker pool (found by
    // sampling a hung run), so this one test runs on the main actor.
    @MainActor
    @Test("the colour tokens resolve to the palette in each appearance")
    func tokensResolveToPalette() {
        func resolved(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            return color.resolve(in: environment)
        }
        func matches(_ r: Color.Resolved, _ shade: SmoothExamPalette.Shade) -> Bool {
            let expected = Self.rgb(shade.hex)
            // `Resolved` is linear-light extended sRGB only in its `linear*`
            // fields; `red`/`green`/`blue` are the gamma-encoded values the
            // palette hex is written in.
            return abs(Double(r.red) - expected.r) < 0.02
                && abs(Double(r.green) - expected.g) < 0.02
                && abs(Double(r.blue) - expected.b) < 0.02
                && abs(Double(r.opacity) - shade.alpha) < 0.02
        }
        let tokens: [(String, Color, SmoothExamPalette.Pair)] = [
            ("fill", .smoothExamFill, SmoothExamPalette.fill),
            ("text", .smoothExamText, SmoothExamPalette.text),
            ("secondary", .smoothExamTextSecondary, SmoothExamPalette.secondaryText),
            ("destructive", .smoothExamDestructive, SmoothExamPalette.destructive),
        ]
        for (name, color, pair) in tokens {
            #expect(matches(resolved(color, .light), pair.light), "\(name) in light mode")
            #expect(matches(resolved(color, .dark), pair.dark), "\(name) in dark mode")
        }
    }
    #endif
}

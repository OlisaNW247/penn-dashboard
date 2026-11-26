import Foundation
import SwiftUI
import Testing
#if canImport(AppKit)
import AppKit
#endif
@testable import LowHangingFruitUI

/// Marco's second look at the v11 UI on 2026-11-11: the hovering shapes on
/// ask, the wordmark's backflip on three taps, and the larger title.
@Suite("UI pass 2026-11-11")
struct UIPassNov11Tests {
    private func uiSource(_ name: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LowHangingFruitUI/\(name)")
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("three taps inside 1.5 s fire once, then the count starts again")
    func tripleTap() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var taps = WordmarkTripleTap()
        let f1 = taps.register(at: t0)
        #expect(!f1)
        let f2 = taps.register(at: t0.addingTimeInterval(0.4))
        #expect(!f2)
        let f3 = taps.register(at: t0.addingTimeInterval(0.9))
        #expect(f3)
        // Reset: the next two taps do not fire, the third does.
        let f4 = taps.register(at: t0.addingTimeInterval(1.0))
        #expect(!f4)
        let f5 = taps.register(at: t0.addingTimeInterval(1.2))
        #expect(!f5)
        let f6 = taps.register(at: t0.addingTimeInterval(1.4))
        #expect(f6)
    }

    @Test("a tap after the window starts a new count")
    func tripleTapWindow() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        var taps = WordmarkTripleTap()
        let f7 = taps.register(at: t0)
        #expect(!f7)
        let f8 = taps.register(at: t0.addingTimeInterval(1.0))
        #expect(!f8)
        // 1.6 s after the first: the window lapsed, this is tap one again.
        let f9 = taps.register(at: t0.addingTimeInterval(1.6))
        #expect(!f9)
        #expect(taps.count == 1)
        let f10 = taps.register(at: t0.addingTimeInterval(2.0))
        #expect(!f10)
        let f11 = taps.register(at: t0.addingTimeInterval(2.5))
        #expect(f11)
    }

    @Test("the backflip is one turn about the x axis, skipped under Reduce Motion, and resets to 0")
    func backflipSource() throws {
        let src = try uiSource("ContentView.swift")
        guard !src.isEmpty else { return }
        #expect(src.contains(".rotation3DEffect(.degrees(flip), axis: (x: 1, y: 0, z: 0)"))
        #expect(src.contains("if taps.register(at: Date()), !reduceMotion {"))
        #expect(src.contains("withAnimation(.easeInOut(duration: 0.8)) { flip = 360 }"))
        #expect(src.contains("withTransaction(t) { flip = 0 }"))
    }

    @Test("each hovering shape stays within 6 pt and 2 degrees, on its own 3 to 6 s period")
    func hoverBounds() {
        for loop in SmoothShapeHover.loops {
            #expect(loop.period >= 3 && loop.period <= 6)
            #expect(loop.amplitude >= 3 && loop.amplitude <= 6)
            #expect(abs(loop.tilt) <= 2)
        }
        #expect(Set(SmoothShapeHover.loops.map(\.period)).count == SmoothShapeHover.loops.count)
        for i in 0..<4 {
            for step in 0..<200 {
                let d = SmoothShapeHover.drift(shape: i, at: Double(step) * 0.137)
                #expect(abs(d.x) <= 6 && abs(d.y) <= 6 && abs(d.degrees) <= 2)
            }
        }
        #expect(SmoothShapeHover.drift(shape: 9, at: 1) == .still)
    }

    @Test("only ask hovers, never while typing or under Reduce Motion, and from a local TimelineView")
    func hoverWiring() throws {
        let ask = try uiSource("AssistantView.swift")
        guard !ask.isEmpty else { return }
        #expect(ask.contains("hovers: !composerFocused && !reduceMotion)"))
        let chrome = try uiSource("SmoothFormChrome.swift")
        #expect(chrome.contains("var hovers: Bool = false"))
        #expect(chrome.contains("TimelineView(.animation"))
        #expect(!chrome.contains("Timer."))
        // Every other caller keeps the default: still.
        for name in ["SettingsPage.swift", "AgentLinkApproveSheet.swift", "SweeperView.swift", "PairLaptopSheet.swift"] {
            #expect(!(try uiSource(name)).contains("hovers:"), "\(name)")
        }
    }

    @Test("Atkinson Hyperlegible Next and its OFL licence are bundled, and the package processes Resources")
    func atkinsonBundled() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/LowHangingFruitUI/Resources")
        for name in ["AtkinsonHyperlegibleNext-Variable.ttf", "AtkinsonHyperlegibleNext-OFL.txt"] {
            #expect(FileManager.default.fileExists(atPath: resources.appendingPathComponent(name).path), "\(name)")
        }
        let licence = try String(contentsOf: resources.appendingPathComponent("AtkinsonHyperlegibleNext-OFL.txt"), encoding: .utf8)
        #expect(licence.contains("SIL Open Font License"))
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(package.contains("resources: [.process(\"Resources\")]"))
        let tokens = try uiSource("RedesignTokens.swift")
        #expect(tokens.contains("(\"AtkinsonHyperlegibleNext-Variable\", \"ttf\")"))
    }

    #if canImport(AppKit)
    @Test("the SemiBold instance resolves by name once the bundled faces are registered")
    func atkinsonResolves() {
        SmoothFonts.ensureRegistered()
        let font = NSFont(name: "AtkinsonHyperlegibleNext-SemiBold", size: 10)
        #expect(font != nil)
        #expect(font?.fontName.hasPrefix("AtkinsonHyperlegibleNext") == true)
    }
    #endif

    @Test("the class code on the card and the review sheet uses lhfCourseCode; NEW and the due value stay mono")
    func courseCodeFace() throws {
        let card = try uiSource("AssignmentCardView.swift")
        guard !card.isEmpty else { return }
        #expect(card.contains(".font(.lhfCourseCode(10))"))
        #expect(!card.contains(".font(.lhfMono(9.5, weight: .semibold))"))
        let sheet = try uiSource("AgentDraftReviewSheet.swift")
        #expect(sheet.contains(".font(.lhfCourseCode(11))"))
        #expect(!sheet.contains(".font(.lhfMono(10.5, weight: .semibold))"))
        #expect(Font.courseCodeTracking == 0.9)
    }
}

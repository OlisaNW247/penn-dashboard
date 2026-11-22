import Foundation
import Testing

/// The intro tour is two pages (the animated story before it already shows
/// the chaos resolving, so a page repeating it was cut), and the onboarding
/// walk's three progress dots are drawn on every page they count: Canvas
/// connected (1), the Gradescope choice (2) and reminders (3).
///
/// Source scans, in the idiom of `SweeperOnboardingTests`: the views are not
/// driven, so these pin that the pieces are there.
@Suite("Intro tour")
struct IntroTourTests {

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func ui(_ filename: String) throws -> String {
        let url = packageRoot().appendingPathComponent("Sources/LowHangingFruitUI/\(filename)")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.path) is not there, so nothing could be checked")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text from `marker` to the next `private ` declaration at member
    /// indentation, so one view's body can be inspected on its own.
    private func slice(_ source: String, from marker: String) throws -> String {
        let start = try #require(source.range(of: marker), "\(marker) not found")
        let rest = source[start.lowerBound...].dropFirst(marker.count)
        let end = rest.range(of: "\n    private ")?.lowerBound ?? rest.endIndex
        return String(source[start.lowerBound...].prefix(marker.count + rest.distance(from: rest.startIndex, to: end)))
    }

    @Test("the tour is two pages and the purpose page is gone")
    func twoPages() throws {
        let source = try ui("MissionIntroView.swift")
        #expect(source.contains("pageCount = 2"))
        #expect(!source.contains("losing points"))
        #expect(!source.contains("MissionScatter"))
        #expect(source.contains("min(Self.pageCount - 1, requested)"))
    }

    @Test("the dots are drawn on the connected, Gradescope and reminders pages")
    func dotsAreTruthful() throws {
        let source = try ui("OnboardingView.swift")
        let connected = try slice(source, from: "private func connectedStep(")
        #expect(connected.contains("progressDots(current: step)"))
        #expect(!connected.contains("step != 1"))
        let invitation = try slice(source, from: "private var gradescopeInvitation")
        #expect(invitation.contains("progressDots(current: 2)"))
        #expect(source.contains("progressDots(current: 3)"))
    }
}

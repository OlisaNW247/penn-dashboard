import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The announcements megaphone moved from the control row into the header on
/// 2026-10-18, taking the place of the grades button (see
/// `GradeWatcherRemovalTests`), and now always shows.
@Suite("Header megaphone")
struct HeaderMegaphoneTests {

    @Test("the badge counts up to 99 and then says 99+")
    func badgeText() {
        #expect(AnnouncementSheetCopy.badgeText(1) == "1")
        #expect(AnnouncementSheetCopy.badgeText(12) == "12")
        #expect(AnnouncementSheetCopy.badgeText(99) == "99")
        #expect(AnnouncementSheetCopy.badgeText(100) == "99+")
        #expect(AnnouncementSheetCopy.badgeText(412) == "99+")
    }

    @Test("an empty list still has one short lowercase line to say")
    func emptyStateIsShortAndLowercase() {
        let line = AnnouncementSheetCopy.emptyState
        #expect(line == line.lowercased())
        #expect(line.split(separator: " ").count <= 3)
    }

    @Test("the megaphone sits in the header, left of profile, and not in the control row")
    func placement() throws {
        let source = try GradeWatcherRemovalTests.uiSource("ContentView.swift")
        guard !source.isEmpty else { return }

        let headerStart = try #require(source.range(of: "private var header: some View"))
        let headerEnd = try #require(source.range(of: "private func headerTitle", range: headerStart.upperBound..<source.endIndex))
        let header = String(source[headerStart.lowerBound..<headerEnd.lowerBound])
        let megaphone = try #require(header.range(of: "announcementFindsButton"))
        let profile = try #require(header.range(of: "navButton(to: .profile"))
        #expect(megaphone.lowerBound < profile.lowerBound)

        // The control row: switch, class filter, add. Nothing else.
        let rowStart = try #require(source.range(of: "DashViewPicker(selection:"))
        let rowEnd = try #require(source.range(of: ".padding(.top, 14)", range: rowStart.upperBound..<source.endIndex))
        let row = String(source[rowStart.lowerBound..<rowEnd.lowerBound])
        #expect(row.contains("ClassFilterMenu"))
        #expect(row.contains("addInlineButton"))
        #expect(!row.contains("announcementFindsButton"))

        // And nothing hides it any more.
        #expect(!source.contains("if state.showsAnnouncementsButton"))
    }
}

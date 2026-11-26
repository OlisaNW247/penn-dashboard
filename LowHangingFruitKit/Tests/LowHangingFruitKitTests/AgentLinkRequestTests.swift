import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite struct AgentLinkRequestTests {
    @Test func parsesTheLink() {
        let link = AgentLinkRequest(text: "smooth://link?c=abcdEFGH12_-xyz")
        #expect(link?.pendingID == "abcdEFGH12_-xyz")
        #expect(AgentLinkRequest(url: URL(string: "smooth://link?c=abcdEFGH12")!)?.pendingID == "abcdEFGH12")
    }

    @Test func refusesEverythingElse() {
        let bad = [
            "smooth://pair?c=abcdEFGH12", "https://link?c=abcdEFGH12", "smooth://link",
            "smooth://link?c=short", "smooth://link?c=abcdEFGH12&x=1", "smooth://link?c=abcdEFGH12&c=abcdEFGH12",
            "smooth://link?x=abcdEFGH12", "smooth://link/extra?c=abcdEFGH12", "smooth://link?c=abcdEFGH12#k=1",
            "smooth://link?c=abcdEFGH12#", "smooth://u:p@link?c=abcdEFGH12", "smooth://link:80?c=abcdEFGH12",
            "smooth://link?c=abcd%20EFGH12", "smooth://link?c=" + String(repeating: "a", count: 65), "",
        ]
        for text in bad { #expect(AgentLinkRequest(text: text) == nil, "\(text)") }
    }

    @Test func normalizesTypedCodes() {
        #expect(AgentUserCode.normalize("bcdf-ghjk") == "BCDFGHJK")
        #expect(AgentUserCode.normalize(" BCDF GHJK ") == "BCDFGHJK")
        #expect(AgentUserCode.normalize("BCDFGHJ") == nil)
        #expect(AgentUserCode.normalize("BCDFGHJKL") == nil)
        #expect(AgentUserCode.normalize("ACDFGHJK") == nil)  // vowel
        #expect(AgentUserCode.normalize("BCDFGHJ1") == nil)
        #expect(AgentUserCode.normalize("") == nil)
    }
}

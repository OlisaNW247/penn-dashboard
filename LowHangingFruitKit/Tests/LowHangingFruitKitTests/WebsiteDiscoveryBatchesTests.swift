import Testing
@testable import LowHangingFruitKit

/// `discover-websites` answers 400 to more than three course ids, so the
/// phone sends them three at a time (plan item 2, 2026-10-25).
@Suite("WebsiteDiscoveryBatches")
struct WebsiteDiscoveryBatchesTests {
    @Test("eight distinct ids with two repeats make chunks of 3, 3 and 2, in first-seen order")
    func dedupesAndChunks() {
        let ids = ["10", "20", "10", "30", "40", "50", "20", "60", "70", "80"]
        let chunks = WebsiteDiscoveryBatches.chunks(of: ids)
        #expect(chunks == [["10", "20", "30"], ["40", "50", "60"], ["70", "80"]])
    }

    @Test("an empty list makes no chunks")
    func emptyList() {
        #expect(WebsiteDiscoveryBatches.chunks(of: []).isEmpty)
    }

    @Test("exactly three ids make one chunk")
    func exactlyThree() {
        #expect(WebsiteDiscoveryBatches.chunks(of: ["1", "2", "3"]) == [["1", "2", "3"]])
    }
}

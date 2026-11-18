import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Sweeper wake log and counts")
struct DebugWakeLogTests {
    func scratch() -> (UserDefaults, String) {
        let name = "lhf.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    #if DEBUG
    @Test("A line reads back with its words, and the log keeps the last 50")
    func recordAndCap() {
        let (d, name) = scratch()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        DebugWakeLog.record(source: .poll, outcome: "cancelled", duration: 0.25,
                            cancelledRequests: 6, cancelledAlarms: 24, defaults: d)
        let line = d.stringArray(forKey: DebugWakeLog.key)?.first ?? ""
        #expect(line.contains(" poll cancelled 250ms cancelled 6 request(s) 24 alarm(s)"))
        for _ in 0..<60 {
            DebugWakeLog.record(source: .bg, outcome: "none", duration: 0, cancelledRequests: 0, cancelledAlarms: 0, defaults: d)
        }
        let all = d.stringArray(forKey: DebugWakeLog.key) ?? []
        #expect(all.count == 50)
        #expect(all.allSatisfy { $0.contains(" bg none ") })
    }
    #endif

    @Test("Counts accumulate and survive a read")
    func counts() {
        let (d, name) = scratch()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        SweeperCounts.increment(SweeperCounts.armed, defaults: d)
        SweeperCounts.increment(SweeperCounts.armed, by: 2, defaults: d)
        SweeperCounts.increment(SweeperCounts.cancelledKey("poll"), defaults: d)
        let s = SweeperCounts.snapshot(defaults: d)
        #expect(s["armed"] == 3)
        #expect(s["cancelledAtObservation.poll"] == 1)
        #expect(SweeperCounts.snapshot(defaults: scratch().0).isEmpty)
    }

    @Test("The log never interpolates a title, an id or a URL")
    func sourceScan() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI/DebugWakeLog.swift")
        let text = try String(contentsOf: path, encoding: .utf8)
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }.joined(separator: "\n")
        for word in ["title", "assignment.id", "url", "URL"] {
            #expect(!code.contains(word), "DebugWakeLog.swift mentions \(word)")
        }
    }
}

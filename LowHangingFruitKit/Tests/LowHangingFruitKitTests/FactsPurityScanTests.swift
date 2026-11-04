import Foundation
import Testing

/// Source-level guards for the facts and structured-sources code, in the
/// `HardeningSourceScan` style: whole-line comments are dropped first, so a
/// comment that names a forbidden call (as a "why" comment does) is not
/// mistaken for the call.
@Suite("Facts and structured sources: purity scans")
struct FactsPurityScanTests {
    private static var kitSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitKit")
    }

    private func kitFiles(in directory: String, matching prefix: String = "") throws -> [(name: String, code: String)] {
        let dir = Self.kitSources.appendingPathComponent(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") && $0.hasPrefix(prefix) }
            .sorted()
        return try names.map { ($0, HardeningSourceScan.codeOnly(try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))) }
    }

    private static let clockReads = ["Date()", "Date.now", "CFAbsoluteTimeGetCurrent", "Calendar.current", "TimeZone.current"]

    @Test("the facts engine and its types never read a clock or the current calendar")
    func factsKitIsPure() throws {
        let files = try kitFiles(in: "Facts")
        #expect(files.count >= 2, "scan found the Facts directory")
        for file in files {
            for call in Self.clockReads { #expect(!file.code.contains(call), "\(file.name) calls \(call)") }
            #expect(!file.code.contains("UserDefaults"), "\(file.name) touches UserDefaults")
        }
    }

    @Test("the structured-source decoders, client and reconciler never read a clock")
    func structuredKitIsPure() throws {
        let files = try kitFiles(in: "Canvas", matching: "CanvasStructuredSources")
        #expect(files.count == 3, "expected decoders, client and reconciler; found \(files.map(\.name))")
        for file in files {
            for call in Self.clockReads { #expect(!file.code.contains(call), "\(file.name) calls \(call)") }
        }
    }

    @Test("the AppState halves use App Group defaults, never UserDefaults.standard")
    func appStateUsesGroupDefaults() throws {
        for name in ["AppState+AppliedFacts.swift", "AppState+StructuredSources.swift"] {
            let code = try HardeningSourceScan.uiCode(name)
            #expect(!code.isEmpty, "\(name) was read")
            #expect(!code.contains("UserDefaults.standard"), "\(name) uses UserDefaults.standard")
        }
    }
}

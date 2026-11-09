import Foundation
import Testing
@testable import LowHangingFruitUI

/// The degree screens' copy rules (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md):
/// lowercase, no verdict words, the official audit always named, and every
/// status sentence read from `DegreeStatus.line` rather than written here.
@Suite("Degree copy")
struct DegreeCopyTests {
    private static let files = ["DegreeProgressView.swift", "DegreeWhatIfSheet.swift"]

    private func uiSource(_ filename: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        return try String(contentsOf: sources.appendingPathComponent(filename), encoding: .utf8)
    }

    @Test("no verdict words anywhere in the degree views")
    func noVerdictWords() throws {
        for file in Self.files {
            let source = try uiSource(file).lowercased()
            for word in ["graduate", "on track", "eligible"] {
                #expect(!source.contains(word), "\(file) contains \(word)")
            }
        }
    }

    @Test("the footer names the official audit")
    func footer() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(source.contains("path@penn's reading · official audit ↗"))
        #expect(source.contains("DegreeWorksEndpoints.officialAuditURL"))
    }

    @Test("no capitalised literal in a visible string")
    func lowercaseLiterals() throws {
        let pattern = try NSRegularExpression(pattern: #"(Text|Button|Link|TextField|Label)\("[A-Z]"#)
        for file in Self.files {
            let source = try uiSource(file)
            let range = NSRange(source.startIndex..., in: source)
            #expect(pattern.firstMatch(in: source, range: range) == nil, "\(file) has a capitalised string")
        }
    }

    @Test("the status sentence comes from DegreeStatus.line, not the view")
    func statusFromLine() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(source.contains("degreeStatus.line(now:"))
        for phrase in ["reading path@penn…", "approve the duo push", "couldn't read path@penn", "pick your degree"] {
            #expect(!source.contains(phrase), "\(phrase) belongs to DegreeStatus")
        }
    }
}

import Foundation
import Testing

/// Source-level checks for the code the package test runner cannot execute:
/// `BackgroundRefresh.swift` is compiled only for iOS, and SwiftUI views are
/// not run here. The same approach `LaunchRefreshStructureTests` takes for
/// `ContentView`, shared so the hardening tests do not each carry a copy.
///
/// The scans look for calls and their order, not indentation, and drop
/// whole-line comments first, so a comment that names a call (as a "why"
/// comment does) is not mistaken for the call.
enum HardeningSourceScan {

    /// Source with whole-line `//` comments (doc comments included) dropped.
    static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// A file of `LowHangingFruitUI`, comments dropped.
    static func uiCode(_ filename: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        let text = try String(contentsOf: sources.appendingPathComponent(filename), encoding: .utf8)
        return codeOnly(text)
    }

    /// The text between the braces of the function whose declaration contains
    /// `signature`, found by matching braces rather than by indentation.
    static func body(ofFunctionDeclaredWith signature: String, in source: String) throws -> String {
        let header = try #require(source.range(of: signature), "no declaration containing \(signature)")
        let open = try #require(source.range(of: "{", range: header.upperBound..<source.endIndex))
        var depth = 1
        var index = open.upperBound
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[open.upperBound..<index]) }
            default: break
            }
            index = source.index(after: index)
        }
        Issue.record("unbalanced braces after \(signature)")
        return ""
    }

    /// Where each of `calls` first appears in `text`, failing the test for a
    /// missing one.
    static func positions(of calls: [String], in text: String) throws -> [String.Index] {
        try calls.map { call in
            try #require(text.range(of: call), "missing \(call)").lowerBound
        }
    }
}

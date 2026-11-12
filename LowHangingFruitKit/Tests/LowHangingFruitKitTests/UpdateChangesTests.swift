import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The update manifest's optional `changes` list: the short "· sweeper button
/// and page" lines under the update wall's and the banner's line. The
/// sanitizer, the fail-open decode, the cache, the store, and a scan that the
/// screens grew no heading or sentence for it.
@Suite("Update change list")
struct UpdateChangesTests {

    private func policy(changes: String?) throws -> UpdatePolicy {
        var fields = ["\"minimumVersion\": \"3.4.1\"", "\"latestVersion\": \"3.4.1\""]
        if let changes { fields.append("\"changes\": \(changes)") }
        let json = "{" + fields.joined(separator: ", ") + "}"
        return try JSONDecoder().decode(UpdatePolicy.self, from: Data(json.utf8))
    }

    @Test("a manifest without the field decodes with no list")
    func absent() throws {
        let decoded = try policy(changes: nil)
        #expect(decoded.minimumVersion == AppVersion("3.4.1"))
        #expect(decoded.changes.isEmpty)
    }

    @Test("a manifest with the field decodes its lines in order")
    func present() throws {
        let decoded = try policy(changes: #"["sweeper button and page", "connect an agent", "drafts you review and submit"]"#)
        #expect(decoded.changes == ["sweeper button and page", "connect an agent", "drafts you review and submit"])
        #expect(decoded.minimumVersion == AppVersion("3.4.1"))
    }

    @Test("an empty array is no list")
    func empty() throws {
        #expect(try policy(changes: "[]").changes.isEmpty)
    }

    @Test("a wrong shape costs the list, never the floor", arguments: [
        "3", "{\"a\": \"b\"}", "\"sweeper button\"", "null", "true",
    ])
    func failOpen(bad: String) throws {
        let decoded = try policy(changes: bad)
        #expect(decoded.minimumVersion == AppVersion("3.4.1"))
        #expect(decoded.latestVersion == AppVersion("3.4.1"))
        #expect(decoded.changes.isEmpty)
    }

    @Test("non-string items are skipped one by one")
    func nonStringItems() throws {
        let decoded = try policy(changes: #"[1, "connect an agent", null, {"x": 1}, ["y"], false, "sweeper page"]"#)
        #expect(decoded.changes == ["connect an agent", "sweeper page"])
        #expect(decoded.minimumVersion == AppVersion("3.4.1"))
    }

    @Test("at most six lines, the first six kept")
    func count() {
        let raw = (1...9).map { "change \($0)" }
        #expect(UpdatePolicy.sanitizedChanges(raw) == (1...6).map { "change \($0)" })
    }

    @Test("a dropped line does not use one of the six")
    func droppedLinesDoNotCount() {
        let raw = ["", "   "] + (1...6).map { "change \($0)" }
        #expect(UpdatePolicy.sanitizedChanges(raw).count == 6)
    }

    @Test("trimmed, whitespace collapsed, lowercased")
    func trimmedAndLowercased() {
        #expect(UpdatePolicy.sanitizedChanges(["  New   Sweeper Button  "]) == ["new sweeper button"])
    }

    @Test("40 characters is the limit; a longer line is dropped, not cut")
    func length() {
        let forty = String(repeating: "a", count: 40)
        let fortyOne = String(repeating: "b", count: 41)
        #expect(UpdatePolicy.sanitizedChanges([forty, fortyOne]) == [forty])
        // Measured after trimming, so padding does not push a short line over.
        #expect(UpdatePolicy.sanitizedChanges(["   " + forty + "   "]) == [forty])
    }

    @Test("control characters become spaces, a line of only them is dropped")
    func controlCharacters() {
        #expect(UpdatePolicy.sanitizedChanges(["sweeper\nbutton", "agent\u{1B}[31mconnection", "\u{0}\u{7}\t"])
            == ["sweeper button", "agent [31mconnection"])
    }

    @Test("a line carrying a link is dropped", arguments: [
        "see https://evil.example",
        "update at itms-apps://apps.apple.com",
        "www.smooth-update.com",
        "go to smooth-update.com now",
    ])
    func links(line: String) {
        #expect(UpdatePolicy.sanitizedChanges([line, "connect an agent"]) == ["connect an agent"])
    }

    @Test("ordinary release lines survive the link check")
    func ordinaryLines() {
        let lines = ["sweeper button and page", "connect an agent", "drafts you review and submit", "fixes for ios 26.1"]
        #expect(UpdatePolicy.sanitizedChanges(lines) == lines)
    }

    @Test("the memberwise init sanitizes too")
    func memberwise() {
        let made = UpdatePolicy(changes: ["  Connect An Agent ", "https://x.example"])
        #expect(made.changes == ["connect an agent"])
    }

    @Test("the cache round-trips the list, and an empty list stays empty")
    func cacheRoundTrip() throws {
        let name = "lhf.tests.updateChanges.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let cache = UpdatePolicyCache(defaults: defaults)
        let at = Date(timeIntervalSince1970: 1_000_000)
        let saved = UpdatePolicy(minimumVersion: AppVersion("3.4.1"), changes: ["sweeper button and page", "connect an agent"])
        cache.save(saved, at: at)
        let loaded = try #require(cache.load(now: at.addingTimeInterval(60)))
        #expect(loaded == saved)
        #expect(loaded.changes == ["sweeper button and page", "connect an agent"])

        cache.save(UpdatePolicy(minimumVersion: AppVersion("3.4.1")), at: at)
        let bare = try #require(cache.load(now: at.addingTimeInterval(60)))
        #expect(bare.changes.isEmpty)
        // An empty list is not written at all, so an older build's cache
        // reads exactly what it read before.
        let data = try #require(defaults.data(forKey: "lhf.updatePolicy"))
        #expect(!String(decoding: data, as: UTF8.self).contains("changes"))
    }

    @MainActor
    @Test("the store takes the list from the cached policy at launch")
    func store() throws {
        let name = "lhf.tests.updateChangesStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let at = Date(timeIntervalSince1970: 1_000_000)
        let cache = UpdatePolicyCache(defaults: defaults)
        cache.save(UpdatePolicy(minimumVersion: AppVersion("2.0.0"), changes: ["connect an agent"]), at: at)

        let store = UpdateGateStore(
            installedVersion: AppVersion("1.0.0"),
            manifestURL: nil,
            session: .shared,
            cache: cache,
            now: { at.addingTimeInterval(100) },
            defaults: defaults,
            clearNotifications: {}
        )
        guard case .updateRequired = store.verdict else {
            Issue.record("expected the wall")
            return
        }
        #expect(store.changes == ["connect an agent"])
    }

    // MARK: The screens

    private func uiSource(_ filename: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI").appendingPathComponent(filename)
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The string literals a source file shows, comments stripped.
    private func literals(_ source: String) -> [String] {
        let code = source
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let range = line.range(of: "//") else { return line }
                return String(line[..<range.lowerBound])
            }
            .joined(separator: "\n")
        let regex = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let range = NSRange(code.startIndex..., in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    @Test("both screens show the list and add no heading or sentence for it")
    func noHeading() throws {
        let wall = try uiSource("UpdateRequiredView.swift")
        let banner = try uiSource("UpdateAvailableBanner.swift")
        #expect(wall.contains("UpdateChangeList(changes: changes"))
        #expect(banner.contains("UpdateChangeList(changes: changes"))

        // The only text either screen shows is what it showed before the
        // list, plus the bullet.
        let wallLiterals = Set(literals(wall))
        #expect(wallLiterals == [
            "update smooth to keep using it.", "time for an update", "update now", "· \\(line)",
        ])
        let bannerLiterals = Set(literals(banner))
        #expect(bannerLiterals == [
            "an update is available", "version \\(latest.description) is out.", "dismiss",
            // SF Symbol names, not shown text.
            "arrow.up.circle.fill", "xmark",
        ])
        for text in wallLiterals.union(bannerLiterals) {
            let lower = text.lowercased()
            #expect(!lower.contains("what's new"))
            #expect(!lower.contains("includes"))
            #expect(!lower.contains("changes"))
        }
    }
}

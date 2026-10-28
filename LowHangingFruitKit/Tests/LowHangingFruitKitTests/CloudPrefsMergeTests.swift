import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// iCloud preferences never delete another device's settings (hardening plan B11,
// DAT-09).
//
// A second device switching sync on has no preferences of its own. The old
// launch seed read "no local value" as "remove the iCloud copy", so it deleted
// every key the first device had pushed, and the first device then pulled the
// removals. `CloudPrefsMirror` is inert under `swift test` (it must never reach
// real iCloud), so the rules live in `CloudPrefsMerge` as pure functions and
// are tested here.

private let keys = ["coursePreferences", "courseContentDecisionsV1", "deletedCourseKeys", "courseNameOverrides", "hiddenCourseKeys"]

private func data(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func object(_ value: Any?) -> [String: Any]? {
    guard let value = value as? Data else { return nil }
    return (try? JSONSerialization.jsonObject(with: value)) as? [String: Any]
}

/// Splits steps into (remote writes, local writes) by key, for readable asserts.
private func split(_ steps: [CloudPrefsMerge.Step]) -> (remote: [String: Any], local: [String: Any]) {
    var remote: [String: Any] = [:]
    var local: [String: Any] = [:]
    for step in steps {
        switch step {
        case let .setRemote(key, value): remote[key] = value
        case let .setLocal(key, value): local[key] = value
        }
    }
    return (remote, local)
}

@Suite("iCloud prefs: a seed never removes")
struct CloudPrefsSeedTests {

    @Test("a second device with no preferences of its own produces no step at all: the DAT-09 regression")
    func emptyDeviceDeletesNothing() {
        let remote: [String: Any] = [
            "hiddenCourseKeys": ["PHYS 0151"],
            "courseNameOverrides": ["CIS 1200": "programming"],
            "coursePreferences": data(["PHYS 0151": ["isVisible": false]]),
        ]
        let steps = CloudPrefsMerge.seedSteps(keys: keys, local: [:], remote: remote)
        #expect(steps.isEmpty, "nothing to push, and in particular nothing to remove")
    }

    @Test("a present local value is pushed when iCloud differs or has none")
    func presentValuesArePushed() {
        let local: [String: Any] = ["hiddenCourseKeys": ["A"], "deletedCourseKeys": ["B"]]
        let remote: [String: Any] = ["hiddenCourseKeys": ["Z"]]
        let (remoteWrites, localWrites) = split(CloudPrefsMerge.seedSteps(keys: keys, local: local, remote: remote))
        #expect(Set(remoteWrites.keys) == ["hiddenCourseKeys", "deletedCourseKeys"])
        #expect(localWrites.isEmpty)
        #expect(remoteWrites["hiddenCourseKeys"] as? [String] == ["A"])
    }

    @Test("a value iCloud already holds equal is not pushed again")
    func equalValuesAreSkipped() {
        let both: [String: Any] = ["hiddenCourseKeys": ["A"], "coursePreferences": data(["x": 1])]
        #expect(CloudPrefsMerge.seedSteps(keys: keys, local: both, remote: both).isEmpty)
    }

    @Test("only the allowlist is ever touched")
    func onlyAllowlistedKeys() {
        let steps = CloudPrefsMerge.seedSteps(keys: ["hiddenCourseKeys"], local: ["somethingElse": "x", "hiddenCourseKeys": ["A"]], remote: [:])
        #expect(split(steps).remote.keys.sorted() == ["hiddenCourseKeys"])
    }
}

@Suite("iCloud prefs: the first meeting merges")
struct CloudPrefsFirstMergeTests {

    @Test("a device with nothing adopts iCloud's values and pushes nothing")
    func emptyDeviceAdopts() {
        let remote: [String: Any] = ["hiddenCourseKeys": ["PHYS 0151"], "courseNameOverrides": ["CIS 1200": "prog"]]
        let (remoteWrites, localWrites) = split(CloudPrefsMerge.mergeSteps(keys: keys, local: [:], remote: remote))
        #expect(remoteWrites.isEmpty, "adopting must never write to iCloud, let alone remove from it")
        #expect(localWrites["hiddenCourseKeys"] as? [String] == ["PHYS 0151"])
        #expect((localWrites["courseNameOverrides"] as? [String: String]) == ["CIS 1200": "prog"])
    }

    @Test("a device with values and an empty iCloud pushes them and changes nothing locally")
    func emptyCloudIsSeeded() {
        let local: [String: Any] = ["hiddenCourseKeys": ["A"]]
        let (remoteWrites, localWrites) = split(CloudPrefsMerge.mergeSteps(keys: keys, local: local, remote: [:]))
        #expect(remoteWrites["hiddenCourseKeys"] as? [String] == ["A"])
        #expect(localWrites.isEmpty)
    }

    @Test("two different copies become one union, written to both sides")
    func differingCopiesUnion() {
        let local: [String: Any] = ["hiddenCourseKeys": ["B", "A"]]
        let remote: [String: Any] = ["hiddenCourseKeys": ["C", "A"]]
        let (remoteWrites, localWrites) = split(CloudPrefsMerge.mergeSteps(keys: keys, local: local, remote: remote))
        #expect(remoteWrites["hiddenCourseKeys"] as? [String] == ["A", "B", "C"])
        #expect(localWrites["hiddenCourseKeys"] as? [String] == ["A", "B", "C"])
    }

    @Test("identical copies need no write, and neither do two empty sides")
    func identicalNeedsNothing() {
        let same: [String: Any] = ["hiddenCourseKeys": ["A"]]
        #expect(CloudPrefsMerge.mergeSteps(keys: keys, local: same, remote: same).isEmpty)
        #expect(CloudPrefsMerge.mergeSteps(keys: keys, local: [:], remote: [:]).isEmpty)
    }
}

@Suite("iCloud prefs: merging one key")
struct CloudPrefsMergedValueTests {

    @Test("either side missing yields the other; both missing yields nothing")
    func missingSides() {
        #expect(CloudPrefsMerge.merged(local: nil, remote: nil) == nil)
        #expect(CloudPrefsMerge.merged(local: ["a"], remote: nil) as? [String] == ["a"])
        #expect(CloudPrefsMerge.merged(local: nil, remote: ["a"]) as? [String] == ["a"])
    }

    @Test("string lists union, sorted and without duplicates")
    func stringLists() {
        let merged = CloudPrefsMerge.merged(local: ["b", "a", "c"], remote: ["c", "d"]) as? [String]
        #expect(merged == ["a", "b", "c", "d"])
    }

    @Test("string maps union their keys, and iCloud's entry wins where both devices have one")
    func stringMaps() {
        let merged = CloudPrefsMerge.merged(
            local: ["CIS 1200": "mine", "MATH 1400": "calc"],
            remote: ["CIS 1200": "theirs", "PHYS 0151": "phys"]
        ) as? [String: String]
        #expect(merged == ["CIS 1200": "theirs", "MATH 1400": "calc", "PHYS 0151": "phys"])
    }

    @Test("JSON objects held as Data union their top-level keys, so neither device's class is dropped")
    func jsonBlobs() throws {
        let local = data(["CIS 1200": ["isVisible": false], "MATH 1400": ["isVisible": true]])
        let remote = data(["PHYS 0151": ["isVisible": false], "CIS 1200": ["isVisible": true]])
        let merged = try #require(object(CloudPrefsMerge.merged(local: local, remote: remote)))

        #expect(Set(merged.keys) == ["CIS 1200", "MATH 1400", "PHYS 0151"])
        let conflicted = try #require(merged["CIS 1200"] as? [String: Bool])
        #expect(conflicted["isVisible"] == true, "iCloud's entry wins for the class both devices have")
    }

    @Test("a merged JSON blob still decodes as the app's own per-class preferences map")
    func mergedBlobDecodes() throws {
        func blob(_ prefs: [String: CoursePreferences]) throws -> Data { try JSONEncoder().encode(prefs) }
        var hidden = CoursePreferences(courseKey: "CIS 1200")
        hidden.isVisible = false
        var renamed = CoursePreferences(courseKey: "MATH 1400")
        renamed.displayName = "calc"
        let merged = try #require(CloudPrefsMerge.merged(local: try blob(["CIS 1200": hidden]), remote: try blob(["MATH 1400": renamed])) as? Data)

        let decoded = CoursePreferencesStore.decodeMap(merged)
        #expect(Set(decoded.keys) == ["CIS 1200", "MATH 1400"])
        #expect(decoded["CIS 1200"]?.isVisible == false)
        #expect(decoded["MATH 1400"]?.displayName == "calc")
    }

    @Test("Data that is not a JSON object falls back to iCloud's copy rather than inventing one")
    func nonObjectData() {
        let local = Data("not json".utf8)
        let remote = data(["a": 1])
        #expect(CloudPrefsMerge.merged(local: local, remote: remote) as? Data == remote)
    }

    @Test("a type mismatch falls back to iCloud's copy")
    func typeMismatch() {
        #expect(CloudPrefsMerge.merged(local: ["a"], remote: "string") as? String == "string")
    }

    @Test("equal values come back unchanged")
    func equalValues() {
        #expect(CloudPrefsMerge.merged(local: ["a"], remote: ["a"]) as? [String] == ["a"])
    }

    @Test("merging is symmetric in what it keeps, so both devices converge on one value")
    func converges() {
        let a: Any = ["x", "y"]
        let b: Any = ["y", "z"]
        let ab = CloudPrefsMerge.merged(local: a, remote: b) as? [String]
        let ba = CloudPrefsMerge.merged(local: b, remote: a) as? [String]
        #expect(ab == ba)
    }
}

@Suite("iCloud prefs: what a launch does")
struct CloudPrefsLaunchActionTests {
    @Test("after the first merge a launch only seeds")
    func laterLaunchesSeed() {
        #expect(CloudPrefsMerge.launchAction(markerSet: true, remoteHasAny: true) == .seedOnly)
        #expect(CloudPrefsMerge.launchAction(markerSet: true, remoteHasAny: false) == .seedOnly)
    }

    @Test("a first enable with iCloud's data already here merges now")
    func firstEnableMerges() {
        #expect(CloudPrefsMerge.launchAction(markerSet: false, remoteHasAny: true) == .mergeNow)
    }

    @Test("a first enable that sees nothing yet waits for the download instead of seeding over it")
    func firstEnableDefers() {
        #expect(CloudPrefsMerge.launchAction(markerSet: false, remoteHasAny: false) == .deferMerge)
    }
}

// MARK: - Wiring pins

@Suite("iCloud prefs: removals are explicit")
struct CloudPrefsRemovalWiringTests {
    private func uiSource(_ filename: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        let file = sources.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Source lines without comments, so a doc comment may name the call.
    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("only pushRemoval and the pull of another device's removal ever remove a key")
    func onlyPushRemovalRemoves() throws {
        let source = try uiSource("CloudPrefsMirror.swift")
        guard !source.isEmpty else { return }

        let body = code(source)
        // Every `removeObject` in the file, and which function holds it.
        let functions = body.components(separatedBy: "\n    func ").dropFirst()
        func function(named name: String) -> String {
            functions.first { $0.hasPrefix(name) }.map { String($0) } ?? ""
        }
        #expect(!function(named: "push(key:").contains("removeObject"))
        #expect(!function(named: "pushAll(").contains("removeObject"))
        #expect(function(named: "pushRemoval(").contains("removeObject"))
    }

    @Test("disconnecting Canvas clears the iCloud content decisions through pushRemoval, not push")
    func disconnectUsesPushRemoval() throws {
        let appState = try uiSource("AppState.swift")
        guard !appState.isEmpty else { return }
        let clear = try #require(appState.range(of: "CourseContentDecisionStore.clear()"))
        let after = String(appState[clear.upperBound...].prefix(900))
        #expect(code(after).contains("cloudPrefsMirror.pushRemoval(key: \"courseContentDecisionsV1\")"))
    }
}

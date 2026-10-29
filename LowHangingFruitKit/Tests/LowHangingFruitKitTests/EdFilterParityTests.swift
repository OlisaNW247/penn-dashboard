import Foundation
import Testing
@testable import LowHangingFruitKit

/// P4 of `docs/HARDENING_PLAN_2026-10-25.md` (SEC-10): the Chrome extension
/// and the app must agree on which Ed threads may become pooled course
/// material.
///
/// The extension re-implements `EdThreadFilter` in JavaScript
/// (`chrome-extension/src/core/ed.js`, "Port of the Ed Discussion pipeline"),
/// and a student's words reaching a shared index because one copy of the rule
/// lagged the other is the failure this guards. Two kinds of check:
///
/// - **Swift alone**: the extension's own filter test cases
///   (`chrome-extension/test/ed.test.js`, each of which is already a mirror of
///   an `EdThreadFilterTests` case) are encoded here and run against
///   `EdThreadFilter`, so the table cannot drift from the app's rule.
/// - **Both implementations, same input**: when `node` is installed, the same
///   raw thread JSON is decoded and decided by `ed.js` itself and by
///   `EdThreadFilter`, over a matrix of every combination of the fields the
///   rule reads. Skipped, not failed, on a machine without `node`.
///
/// **Known divergence, pinned as a known issue.** `EdThreadFilter` drops
/// anonymous threads (`docs/PRIVACY.md` promises it; enforced since
/// 2026-10-23). `ed.js`'s `decide()` has no such rule: it decodes
/// `isAnonymous` and never reads it, so an anonymous announcement or pinned
/// post is kept by the extension and uploaded to the pool. That is a
/// privacy gap in `chrome-extension/src/core/ed.js`, which this change does
/// not edit. The parity check for it is wrapped in `withKnownIssue`: the
/// suite stays green while the gap is open, and fails with "known issue was
/// not recorded" the moment the extension is fixed, which is the cue to
/// delete the wrapper.
@Suite("Ed thread filter: app and extension agree", .serialized)
struct EdFilterParityTests {

    // MARK: Swift alone: the extension's own cases

    private func thread(
        type: String = "post", pinned: Bool = false, isPrivate: Bool = false, anonymous: Bool = false
    ) -> EdThread {
        EdThread(
            id: 1, userID: 1, courseID: 101, type: type, title: "T",
            isPinned: pinned, isPrivate: isPrivate, isAnonymous: anonymous
        )
    }

    @Test("the extension's filter test cases hold for EdThreadFilter")
    func extensionCasesHoldInSwift() {
        let drop = EdThreadDecision(keep: false, reason: "student or question")

        // ed.test.js: "a private announcement is dropped: private beats everything"
        #expect(EdThreadFilter.decide(thread(type: "announcement", isPrivate: true), authorRole: "admin")
            == EdThreadDecision(keep: false, reason: "private"))
        // "announcements are kept whoever wrote them"
        #expect(EdThreadFilter.decide(thread(type: "announcement"), authorRole: nil)
            == EdThreadDecision(keep: true, reason: "announcement"))
        // "a pinned student post is kept: only staff can pin"
        #expect(EdThreadFilter.decide(thread(pinned: true), authorRole: "student")
            == EdThreadDecision(keep: true, reason: "pinned"))
        // "a staff post is kept, in any case, for every staff role"
        for role in ["admin", "Staff", "INSTRUCTOR", "ta", "tutor", "mentor"] {
            #expect(EdThreadFilter.decide(thread(), authorRole: role)
                == EdThreadDecision(keep: true, reason: "staff post"), "\(role)")
        }
        // "a staff question is dropped"
        #expect(EdThreadFilter.decide(thread(type: "question"), authorRole: "staff") == drop)
        // "a student post is dropped, and an unknown author is treated as a student"
        #expect(EdThreadFilter.decide(thread(), authorRole: "student") == drop)
        #expect(EdThreadFilter.decide(thread(), authorRole: nil) == drop)
        #expect(EdThreadFilter.decide(thread(), authorRole: "something-new") == drop)
    }

    @Test("an anonymous thread is dropped whatever it is: announcement, pinned or staff")
    func anonymousIsDroppedInSwift() {
        for role in [nil, "student", "admin", "ta"] as [String?] {
            for type in ["post", "question", "announcement"] {
                for pinned in [false, true] {
                    let decision = EdThreadFilter.decide(
                        thread(type: type, pinned: pinned, anonymous: true), authorRole: role
                    )
                    #expect(!decision.keep, "\(type) pinned=\(pinned) role=\(role ?? "nil") was kept")
                    #expect(decision.reason == "anonymous")
                }
            }
        }
        // Private still wins the label, as the rule order says.
        #expect(EdThreadFilter.decide(thread(isPrivate: true, anonymous: true), authorRole: "admin").reason == "private")
    }

    // MARK: Both implementations, same input

    #if os(macOS)
    private static let extensionDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LowHangingFruitKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // LowHangingFruitKit
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("chrome-extension", isDirectory: true)

    private static let edModule = extensionDirectory.appendingPathComponent("src/core/ed.js")

    private static let nodeURL: URL? = {
        var candidates = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/node" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }()

    private static let canRunExtension = nodeURL != nil && FileManager.default.fileExists(atPath: edModule.path)

    /// One raw thread (as Ed's JSON spells it) and the author's role.
    private struct Case: Sendable {
        let fields: [String: Any & Sendable]
        let role: String?
        var label: String {
            let keys = fields.keys.filter { $0 != "id" && $0 != "course_id" && $0 != "title" && $0 != "created_at" }.sorted()
            return keys.map { "\($0)=\(fields[$0]!)" }.joined(separator: " ") + " role=\(role ?? "nil")"
        }
    }

    private struct Decision: Equatable, CustomStringConvertible {
        let keep: Bool
        let reason: String
        var description: String { "\(keep ? "keep" : "drop")(\(reason))" }
    }

    /// Every combination of what the rule reads. A field is sometimes left
    /// out altogether, because `is_private` missing means private and
    /// `is_anonymous` missing means not, and the two implementations have to
    /// agree on those defaults too.
    private static func matrix(anonymous: [Bool?]) -> [Case] {
        var cases: [Case] = []
        let types = ["post", "question", "announcement", "Announcement", "QUESTION", "poll"]
        let flags: [Bool?] = [nil, false, true]
        let roles: [String?] = [nil, "student", "staff", "Instructor", "ADMIN", "ta", "tutor", "mentor", "something-new"]
        for type in types {
            for isPrivate in flags {
                for pinned in flags {
                    for isAnonymous in anonymous {
                        for role in roles {
                            var fields: [String: Any & Sendable] = [
                                "id": 1, "course_id": 101, "type": type, "title": "T",
                                "created_at": "2026-03-05T14:21:55Z", "user_id": 1,
                            ]
                            if let isPrivate { fields["is_private"] = isPrivate }
                            if let pinned { fields["is_pinned"] = pinned }
                            if let isAnonymous { fields["is_anonymous"] = isAnonymous }
                            cases.append(Case(fields: fields, role: role))
                        }
                    }
                }
            }
        }
        return cases
    }

    private static func swiftDecision(_ testCase: Case) throws -> Decision {
        let data = try JSONSerialization.data(withJSONObject: testCase.fields)
        let thread = try EdJSON.decoder().decode(EdThread.self, from: data)
        let decision = EdThreadFilter.decide(thread, authorRole: testCase.role)
        return Decision(keep: decision.keep, reason: decision.reason)
    }

    /// Runs `ed.js`'s own `decodeThread` and `decide` over `cases`, and reads
    /// its `STAFF_ROLES`.
    private static func extensionDecisions(_ cases: [Case]) throws -> (decisions: [Decision], staffRoles: Set<String>) {
        let script = """
        import { readFileSync } from "node:fs";
        import { decodeThread, decide, STAFF_ROLES } from "\(edModule.absoluteString)";
        const cases = JSON.parse(readFileSync(0, "utf8"));
        const decisions = cases.map((c) => decide(decodeThread(c.thread), c.role));
        process.stdout.write(JSON.stringify({ decisions, staffRoles: [...STAFF_ROLES] }));
        """
        let payload = try JSONSerialization.data(withJSONObject: cases.map {
            ["thread": $0.fields, "role": $0.role as Any]
        })

        let process = Process()
        process.executableURL = try #require(nodeURL)
        process.arguments = ["--input-type=module", "-e", script]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(payload)
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Issue.record("node failed: \(String(decoding: err, as: UTF8.self))")
            return ([], [])
        }

        struct Result: Decodable {
            struct D: Decodable { let keep: Bool; let reason: String }
            let decisions: [D]
            let staffRoles: [String]
        }
        let decoded = try JSONDecoder().decode(Result.self, from: out)
        return (decoded.decisions.map { Decision(keep: $0.keep, reason: $0.reason) }, Set(decoded.staffRoles))
    }

    @Test(
        "for every combination of the fields the rule reads, the extension decides what the app decides",
        .enabled(if: canRunExtension, "needs node and the chrome-extension directory")
    )
    func bothImplementationsAgree() throws {
        // Anonymous left out: that rule is the known divergence, below.
        let cases = Self.matrix(anonymous: [nil, false])
        #expect(cases.count > 500)
        let extensionSide = try Self.extensionDecisions(cases)
        #expect(extensionSide.decisions.count == cases.count)

        var disagreements: [String] = []
        for (testCase, theirs) in zip(cases, extensionSide.decisions) {
            let ours = try Self.swiftDecision(testCase)
            if ours != theirs { disagreements.append("\(testCase.label): app \(ours), extension \(theirs)") }
        }
        #expect(disagreements.isEmpty, "\(disagreements.count) disagree, e.g. \(disagreements.prefix(5))")
    }

    @Test(
        "the staff role lists are the same list",
        .enabled(if: canRunExtension, "needs node and the chrome-extension directory")
    )
    func staffRolesMatch() throws {
        let extensionSide = try Self.extensionDecisions(Self.matrix(anonymous: [nil]).prefix(1).map { $0 })
        #expect(extensionSide.staffRoles == EdThreadFilter.staffRoles)
        #expect(!extensionSide.staffRoles.isEmpty)
    }

    @Test(
        "the extension drops anonymous threads, as the app does",
        .enabled(if: canRunExtension, "needs node and the chrome-extension directory")
    )
    func extensionDropsAnonymous() throws {
        let cases = Self.matrix(anonymous: [true])
        let extensionSide = try Self.extensionDecisions(cases)
        #expect(extensionSide.decisions.count == cases.count)

        var kept: [String] = []
        for (testCase, theirs) in zip(cases, extensionSide.decisions) where theirs.keep {
            kept.append(testCase.label)
        }
        // The app drops every one of these. Counted against the app's own
        // answer, so this cannot pass by the app changing its mind.
        for testCase in cases { #expect(try !Self.swiftDecision(testCase).keep, "\(testCase.label)") }

        #expect(kept.isEmpty, "\(kept.count) anonymous threads kept by the extension, e.g. \(kept.prefix(3))")
    }
    #endif
}

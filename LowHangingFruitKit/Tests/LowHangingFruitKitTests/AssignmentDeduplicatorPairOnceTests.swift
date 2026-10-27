import Foundation
import Testing
@testable import LowHangingFruitKit

/// D1 of `docs/HARDENING_PLAN_2026-10-25.md`: pair once, normalise once.
///
/// The rewrite of `AssignmentDeduplicator.matchPairs` (titles normalised once
/// per item, the Gradescope side bucketed by course) and the new
/// `merge(pairs:)` must change nothing a student can see. These tests hold
/// them to the algorithm they replaced: a verbatim copy of the old scan is
/// kept here as the oracle, and both are run over a fixture of a few hundred
/// items built to hit every tier (exact title, fuzzy title, the 21-day guard,
/// undated rows, generic repeating titles, ids that repeat, and stored
/// pairings both good and stale).
@Suite("Assignment deduplication: pair once, normalise once")
struct AssignmentDeduplicatorPairOnceTests {

    // MARK: The oracle: the pairing exactly as it was before D1

    /// The old `matchPairs`, copied from 77b9fbb with only the access paths
    /// changed (`normalize` through `@testable`, `jaccardSimilarity` inlined).
    /// Do not "tidy" this: its value is that it is the slow, obvious version.
    private static func oracleMatchPairs(
        canvasItems: [Assignment],
        gradescopeItems: [Assignment],
        confirmedPairings: [AssignmentDeduplicator.Match]
    ) -> [AssignmentDeduplicator.Match] {
        guard !canvasItems.isEmpty, !gradescopeItems.isEmpty else { return [] }

        struct Candidate {
            let canvas: Assignment
            let gradescope: Assignment
            let score: Double
        }

        func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
            let union = a.union(b).count
            guard union > 0 else { return 0 }
            return Double(a.intersection(b).count) / Double(union)
        }
        func score(_ canvas: Assignment, _ gradescope: Assignment) -> Double {
            let tokensA = AssignmentDeduplicator.normalize(canvas.title)
            let tokensB = AssignmentDeduplicator.normalize(gradescope.title)
            if tokensA == tokensB { return 2.0 }
            return jaccard(Set(tokensA), Set(tokensB))
        }
        func gap(_ a: Date?, _ b: Date?) -> TimeInterval {
            guard let a, let b else { return .greatestFiniteMagnitude }
            return abs(a.timeIntervalSince(b))
        }

        let canvasIDs = Set(canvasItems.map(\.id))
        let gradescopeIDs = Set(gradescopeItems.map(\.id))
        var matches: [AssignmentDeduplicator.Match] = []
        var usedCanvasIDs: Set<String> = []
        var usedGradescopeIDs: Set<String> = []
        for pairing in confirmedPairings {
            guard canvasIDs.contains(pairing.canvasID),
                  gradescopeIDs.contains(pairing.gradescopeID),
                  !usedCanvasIDs.contains(pairing.canvasID),
                  !usedGradescopeIDs.contains(pairing.gradescopeID)
            else { continue }
            usedCanvasIDs.insert(pairing.canvasID)
            usedGradescopeIDs.insert(pairing.gradescopeID)
            matches.append(pairing)
        }

        var candidates: [Candidate] = []
        for canvasItem in canvasItems where !usedCanvasIDs.contains(canvasItem.id) {
            for gradescopeItem in gradescopeItems
            where gradescopeItem.course == canvasItem.course
                && !usedGradescopeIDs.contains(gradescopeItem.id) {
                guard AssignmentDeduplicator.isLikelyDuplicate(
                    titleA: canvasItem.title, dueA: canvasItem.dueAt,
                    titleB: gradescopeItem.title, dueB: gradescopeItem.dueAt
                ) else { continue }
                candidates.append(Candidate(
                    canvas: canvasItem, gradescope: gradescopeItem,
                    score: score(canvasItem, gradescopeItem)
                ))
            }
        }
        let ordered = candidates.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let gapA = gap(a.canvas.dueAt, a.gradescope.dueAt)
            let gapB = gap(b.canvas.dueAt, b.gradescope.dueAt)
            if gapA != gapB { return gapA < gapB }
            return a.canvas.id < b.canvas.id
        }
        for candidate in ordered {
            guard !usedCanvasIDs.contains(candidate.canvas.id),
                  !usedGradescopeIDs.contains(candidate.gradescope.id)
            else { continue }
            usedCanvasIDs.insert(candidate.canvas.id)
            usedGradescopeIDs.insert(candidate.gradescope.id)
            matches.append(AssignmentDeduplicator.Match(
                canvasID: candidate.canvas.id, gradescopeID: candidate.gradescope.id
            ))
        }
        return matches
    }

    // MARK: Fixture

    private static let base = Date(timeIntervalSince1970: 1_790_000_000)
    private static let day: TimeInterval = 86_400

    private struct Fixture {
        var canvas: [Assignment] = []
        var gradescope: [Assignment] = []
        var stored: [AssignmentDeduplicator.Match] = []
    }

    /// Six classes, ~330 Canvas and ~270 Gradescope rows. Deterministic from
    /// the seed.
    private static func fixture(seed: UInt64) -> Fixture {
        var rng = SeededGenerator(seed: seed)
        var fixture = Fixture()
        let courses = ["CIS 1200", "CIS 2400", "MATH 1410", "PHYS 0151", "ECON 0100", "WRIT 0020"]
        let stems = ["Homework", "Problem Set", "Lab", "Project", "Quiz", "Worksheet", "Reading Response", "Essay"]
        // Spellings of one title, which the normaliser is meant to fold.
        func respell(_ title: String, _ roll: Int) -> String {
            switch roll {
            case 0: return title
            case 1: return title.replacingOccurrences(of: "Homework", with: "HW")
            case 2: return title.uppercased()
            case 3: return title + " (Written)"           // fuzzy tier
            case 4: return title.replacingOccurrences(of: " ", with: "")
            case 5: return "Take " + title                 // not the same title
            default: return title
            }
        }

        for (courseIndex, course) in courses.enumerated() {
            for index in 0..<55 {
                let stem = stems[Int.random(in: 0..<stems.count, using: &rng)]
                // A third of the numbers repeat across the term, so generic
                // titles collide and the tie-breaks are exercised.
                let number = Int.random(in: 1...20, using: &rng)
                let title = "\(stem) \(number)"
                let due: Date? = Int.random(in: 0..<12, using: &rng) == 0
                    ? nil
                    : base.addingTimeInterval(Double(index * 3 + courseIndex) * day + Double(Int.random(in: 0..<86_400, using: &rng)))
                var canvasID = "c\(courseIndex)-\(index)"
                if index == 54 { canvasID = "c\(courseIndex)-0" }   // a repeated id
                fixture.canvas.append(Assignment(
                    source: .canvas, sourceID: canvasID, kind: .assignment,
                    course: course, title: title, dueAt: due, url: nil
                ))

                // Most Canvas rows have a Gradescope twin or near twin.
                guard index < 45, Int.random(in: 0..<10, using: &rng) < 8 else { continue }
                let gradescopeTitle = respell(title, Int.random(in: 0...6, using: &rng))
                var gradescopeDue = due
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: gradescopeDue = due.map { $0.addingTimeInterval(Double(Int.random(in: -30...30, using: &rng)) * 3600) }
                case 1: gradescopeDue = due.map { $0.addingTimeInterval(25 * day) }       // past the 21-day guard
                case 2: gradescopeDue = nil
                default: break
                }
                fixture.gradescope.append(Assignment(
                    source: .gradescope, sourceID: "g\(courseIndex)-\(index)", kind: .assignment,
                    course: course, title: gradescopeTitle, dueAt: gradescopeDue, url: nil
                ))
            }
        }
        // A Gradescope-only class and a Canvas-only class, so empty buckets
        // are met on both sides.
        fixture.gradescope.append(Assignment(
            source: .gradescope, sourceID: "g-solo", kind: .assignment,
            course: "ARTH 0100", title: "Homework 1", dueAt: base, url: nil
        ))
        fixture.canvas.append(Assignment(
            source: .canvas, sourceID: "c-solo", kind: .assignment,
            course: "MUSC 0050", title: "Homework 1", dueAt: base, url: nil
        ))

        // Stored pairings: some real twins, one pointing at a row that is
        // gone, one reusing a canvas id, one reusing a gradescope id.
        fixture.stored = [
            .init(canvasID: "canvas:c0-3", gradescopeID: "gradescope:g0-3"),
            .init(canvasID: "canvas:c1-7", gradescopeID: "gradescope:g1-9"),     // a pairing the heuristic may not make
            .init(canvasID: "canvas:c2-1", gradescopeID: "gradescope:g-deleted"),
            .init(canvasID: "canvas:c0-3", gradescopeID: "gradescope:g0-4"),
            .init(canvasID: "canvas:c3-5", gradescopeID: "gradescope:g0-3"),
        ]
        return fixture
    }

    // MARK: Equivalence

    @Test("the bucketed pairing returns exactly what the old scan returned, in the same order")
    func pairingMatchesTheOldScan() {
        for seed in [1, 2, 3, 42, 2026] as [UInt64] {
            let fixture = Self.fixture(seed: seed)
            #expect(fixture.canvas.count >= 300 && fixture.gradescope.count >= 200, "fixture size")
            for stored in [[], fixture.stored] {
                let expected = Self.oracleMatchPairs(
                    canvasItems: fixture.canvas, gradescopeItems: fixture.gradescope, confirmedPairings: stored
                )
                let actual = AssignmentDeduplicator.matchPairs(
                    canvasItems: fixture.canvas, gradescopeItems: fixture.gradescope, confirmedPairings: stored
                )
                #expect(actual == expected, "seed \(seed), \(stored.count) stored")
                // The fixture has to exercise the thing: plenty of pairs, and
                // both tiers among them.
                #expect(actual.count >= 100, "seed \(seed): only \(actual.count) pairs")
            }
        }
    }

    @Test("merge(pairs:) gives the same dashboard list as the merge that paired again")
    func mergeWithFinishedPairsMatchesTheOldMerge() {
        for seed in [1, 2, 3, 42, 2026] as [UInt64] {
            let fixture = Self.fixture(seed: seed)
            // What the rebuild did before: pair, then hand the pairs back as
            // "confirmed" so `merge` pairs the leftovers a second time.
            let pairs = AssignmentDeduplicator.matchPairs(
                canvasItems: fixture.canvas, gradescopeItems: fixture.gradescope, confirmedPairings: fixture.stored
            )
            let old = AssignmentDeduplicator.merge(
                canvasItems: fixture.canvas, gradescopeItems: fixture.gradescope, confirmedPairings: pairs
            )
            let new = AssignmentDeduplicator.merge(
                canvasItems: fixture.canvas, gradescopeItems: fixture.gradescope, pairs: pairs
            )
            #expect(new == old, "seed \(seed)")
            // And both agree with merging from scratch in one call.
            #expect(new == AssignmentDeduplicator.merge(
                canvasItems: fixture.canvas, gradescopeItems: fixture.gradescope, confirmedPairings: fixture.stored
            ), "seed \(seed), one call")
            #expect(new.count < fixture.canvas.count + fixture.gradescope.count)
        }
    }

    @Test("merge(pairs:) collapses exactly the pairs it is given and runs no heuristic")
    func mergeWithPairsRunsNoHeuristic() {
        let canvas = Assignment(
            source: .canvas, sourceID: "1", kind: .assignment, course: "CIS 1200",
            title: "Homework 3", dueAt: Self.base, url: nil
        )
        let gradescope = Assignment(
            source: .gradescope, sourceID: "9", kind: .assignment, course: "CIS 1200",
            title: "Homework 3", dueAt: Self.base, url: nil
        )
        // Same title, same day: the heuristic would pair them.
        #expect(AssignmentDeduplicator.merge(canvasItems: [canvas], gradescopeItems: [gradescope]).count == 1)
        // Given no pairs, nothing collapses.
        let untouched = AssignmentDeduplicator.merge(canvasItems: [canvas], gradescopeItems: [gradescope], pairs: [])
        #expect(untouched == [canvas, gradescope])
        // Given the pair, it collapses onto the Canvas row and records the link.
        let merged = AssignmentDeduplicator.merge(
            canvasItems: [canvas], gradescopeItems: [gradescope],
            pairs: [.init(canvasID: canvas.id, gradescopeID: gradescope.id)]
        )
        #expect(merged.count == 1)
        #expect(merged.first?.id == canvas.id)
        #expect(merged.first?.linkedID == gradescope.id)
        // A pair naming rows that are not there collapses nothing.
        let stale = AssignmentDeduplicator.merge(
            canvasItems: [canvas], gradescopeItems: [gradescope],
            pairs: [.init(canvasID: "canvas:nope", gradescopeID: "gradescope:nope")]
        )
        #expect(stale == [canvas, gradescope])
    }
}

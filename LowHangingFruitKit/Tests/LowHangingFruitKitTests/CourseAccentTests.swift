import Testing
@testable import LowHangingFruitUI

@Suite("Course accent")
struct CourseAccentTests {
    @Test("stable across repeated calls for the same code")
    func stableForSameCode() {
        let first = courseAccentIndex(for: "PHYS 151")
        let second = courseAccentIndex(for: "PHYS 151")
        #expect(first == second)
    }

    @Test("different codes can land on different indices, all in range")
    func inRange() {
        let codes = ["PHYS 151", "CIS 1200", "ENGL 1234", "", "MATH 1400"]
        for code in codes {
            let index = courseAccentIndex(for: code)
            #expect(index >= 0 && index < 6)
        }
    }

    @Test("not derived from String.hashValue, which is randomized per process")
    func matchesFixedFNV() {
        // FNV-1a of "PHYS 151" computed independently; pins the algorithm so
        // a future change to the hash is a visible, deliberate diff rather
        // than a silent chip-color shuffle.
        #expect(courseAccentIndex(for: "PHYS 151") == courseAccentIndex(for: "PHYS 151"))
        #expect(courseAccentIndex(for: "PHYS 151") == fnv1aMod6("PHYS 151"))
    }

    private func fnv1aMod6(_ code: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in code.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % 6)
    }
}

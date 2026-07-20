import Foundation
import Testing
@testable import LowHangingFruitKit

/// Boundary coverage for the percent → 4.0-scale estimate (docs/grades.md §11).
@Suite("Grade scale")
struct GradeScaleTests {

    @Test("Cutoff boundaries land on the right step")
    func boundaries() {
        #expect(GradeScale.gpa(forPercent: 93) == 4.0)      // A starts at 93
        #expect(GradeScale.gpa(forPercent: 92.99) == 3.7)   // just under is A-
        #expect(GradeScale.gpa(forPercent: 90) == 3.7)
        #expect(GradeScale.gpa(forPercent: 89.9) == 3.3)
        #expect(GradeScale.gpa(forPercent: 87) == 3.3)
        #expect(GradeScale.gpa(forPercent: 83) == 3.0)
        #expect(GradeScale.gpa(forPercent: 80) == 2.7)
        #expect(GradeScale.gpa(forPercent: 77) == 2.3)
        #expect(GradeScale.gpa(forPercent: 73) == 2.0)
        #expect(GradeScale.gpa(forPercent: 70) == 1.7)
        #expect(GradeScale.gpa(forPercent: 67) == 1.3)
        #expect(GradeScale.gpa(forPercent: 60) == 1.0)
        #expect(GradeScale.gpa(forPercent: 59.9) == 0.0)
    }

    @Test("Extra credit above 100 is still a 4.0, not an overflow")
    func extraCredit() {
        #expect(GradeScale.gpa(forPercent: 104.2) == 4.0)
    }

    @Test("Zero and negative-proof floor")
    func floor() {
        #expect(GradeScale.gpa(forPercent: 0) == 0.0)
    }
}

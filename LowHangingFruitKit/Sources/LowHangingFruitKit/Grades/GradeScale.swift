import Foundation

/// Percent → 4.0-scale conversion for the term summary (docs/grades.md §11).
///
/// Professors set their own letter cutoffs, and Canvas doesn't expose them, so
/// this is an **estimate** on the standard cutoffs mapped to Penn's scale
/// (A+ and A both 4.0; no D−). The UI must always label the result
/// "estimated" — and per-class numbers stay percentages (§8's letter-grade
/// cut still applies to the cards; only the term summary converts).
public enum GradeScale {
    public static func gpa(forPercent percent: Double) -> Double {
        switch percent {
        case 93...:     return 4.0  // A / A+ (extra credit can push past 100)
        case 90..<93:   return 3.7  // A-
        case 87..<90:   return 3.3  // B+
        case 83..<87:   return 3.0  // B
        case 80..<83:   return 2.7  // B-
        case 77..<80:   return 2.3  // C+
        case 73..<77:   return 2.0  // C
        case 70..<73:   return 1.7  // C-
        case 67..<70:   return 1.3  // D+
        case 60..<67:   return 1.0  // D
        default:        return 0.0  // F
        }
    }
}

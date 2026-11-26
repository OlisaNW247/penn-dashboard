import Foundation

/// The two numbers an ambassador is working toward (Marco, 2026-11-22): 100
/// downloads at their school and 30 posters up. Pure, so the bar and its
/// caption are pinned without a view.
public enum AmbassadorGoals {
    public static let downloadsTarget = 100
    public static let postersTarget = 30

    /// 0...1, so a count past the goal fills the bar and no more.
    public static func progress(count: Int, target: Int) -> Double {
        guard target > 0 else { return 0 }
        return min(1, max(0, Double(count) / Double(target)))
    }

    public static func caption(count: Int, target: Int) -> String {
        "\(count) of \(target)"
    }
}

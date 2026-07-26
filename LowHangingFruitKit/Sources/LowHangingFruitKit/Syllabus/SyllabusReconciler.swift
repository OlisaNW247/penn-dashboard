import Foundation

/// A category where the syllabus promises more work than Canvas is showing.
///
/// This is the gap that makes syllabus ingestion worth the trouble: professors
/// routinely create assignments a week before they're due, so Canvas's list of
/// "what's left" is an undercount for most of the term. A syllabus that says
/// "ten problem sets" lets the report say so out loud instead of quietly
/// planning around seven.
public struct SyllabusCountGap: Sendable, Hashable, Identifiable {
    public let categoryID: String
    public let categoryName: String
    /// What the syllabus said to expect.
    public let expected: Int
    /// What Canvas currently lists (scored or not).
    public let listedInCanvas: Int

    public var id: String { categoryID }
    /// Items the syllabus expects that Canvas hasn't published yet.
    public var missing: Int { max(0, expected - listedInCanvas) }

    public init(categoryID: String, categoryName: String, expected: Int, listedInCanvas: Int) {
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.expected = expected
        self.listedInCanvas = listedInCanvas
    }
}

public enum SyllabusReconciler {
    /// Compares each mapped syllabus category's expected item count against
    /// what Canvas lists for the group it maps to.
    ///
    /// Only applied mappings count: an unconfirmed fuzzy guess shouldn't
    /// produce a confident claim about missing work. A category where Canvas
    /// already lists as many items as the syllabus promised is not returned —
    /// there's nothing to say about it.
    public static func countGaps(
        match: SyllabusMatcher.Result,
        scheme: SyllabusGradingScheme,
        canvasCategories: [GradeCategory]
    ) -> [SyllabusCountGap] {
        let expectedByID = Dictionary(
            scheme.categories.compactMap { category -> (String, Int)? in
                guard let count = category.expectedItemCount else { return nil }
                return (category.id, count)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let canvasByID = Dictionary(uniqueKeysWithValues: canvasCategories.map { ($0.id, $0) })

        return match.matches.compactMap { match -> SyllabusCountGap? in
            guard match.isApplied,
                  let canvasID = match.canvasCategoryID,
                  let canvas = canvasByID[canvasID],
                  let expected = expectedByID[match.syllabusCategoryID]
            else { return nil }

            // Excused and omitted items aren't work the student still owes, so
            // they shouldn't count toward "Canvas already lists this many."
            let listed = canvas.items.filter { !$0.isExcused && !$0.omitFromFinalGrade }.count
            guard expected > listed else { return nil }
            return SyllabusCountGap(
                categoryID: canvasID,
                categoryName: canvas.name,
                expected: expected,
                listedInCanvas: listed
            )
        }
        .sorted { $0.missing > $1.missing }
    }
}

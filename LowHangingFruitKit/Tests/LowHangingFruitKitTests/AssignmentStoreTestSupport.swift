import Testing
@testable import LowHangingFruitKit

/// The two ledger reads that now say "I could not read the ledger" (nil)
/// instead of answering as though it were empty (hardening plan 2026-10-25,
/// B6). A test that is not about read failures expects a readable ledger, so
/// it asks through these: a nil is recorded as a failure of that test, and the
/// neutral answer is returned only so the rest of the test can carry on and
/// report what else is wrong. The wrong shortcut is to unwrap with `?? .empty`
/// in each test, which is the very reading this change removes: a nil would
/// then pass any assertion about an empty set.
extension AssignmentStore {
    func completionRecordOrFail(
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> CompletionRecord {
        guard let record = completionRecord() else {
            Issue.record("the ledger could not be read", sourceLocation: sourceLocation)
            return .empty
        }
        return record
    }

    func holdsFeedRowsOrFail(
        ignoring ignoredIDs: Set<String> = [],
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        guard let answer = holdsFeedRows(ignoring: ignoredIDs) else {
            Issue.record("the ledger could not be read", sourceLocation: sourceLocation)
            return false
        }
        return answer
    }
}

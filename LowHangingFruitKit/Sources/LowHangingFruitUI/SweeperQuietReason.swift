import Foundation

/// Why the Sweeper stays quiet for an item, as a word the Sweeper page and the
/// DEBUG row can show. One item gets at most one reason, the first that
/// applies in `SweeperSettings.quietReason`'s order. `nil` from that function
/// means armed.
///
/// **Marco's decision (2026-11-18):** an item due days ahead with a Canvas or
/// Gradescope id and none of the reasons below is armed today, as it always
/// was; being unconfirmed is never a reason to be quiet. Only a confirmed
/// submission cancels (`SubmissionObservation`).
enum SweeperQuietReason: String, CaseIterable, Sendable {
    /// The general word, kept for grouping in the DEBUG row. The rule itself
    /// returns the finer `inClass` or `offCanvas`, never this.
    case nothingToSubmit
    case inClass
    case offCanvas
    case recurring
    case foundExam
    case classOff
    case remindersOff
    /// Reserved seam for a verdict pooled from classmates. Nobody produces it.
    case pooledVerdict
}

#if canImport(AlarmKit) && os(iOS)
import Foundation
import AlarmKit

/// What a Berserk alarm carries along with it, and the one type the app and
/// the widget extension have to agree on.
///
/// **Why it lives in the Kit.** The Live Activity that draws an alarm's lock
/// screen card and Dynamic Island is a `Widget` in the widget extension
/// (`LHFWidget/BerserkAlarmActivity.swift`), which links this package's Kit
/// product and not `LowHangingFruitUI`. A Live Activity is decoded from the
/// exact attributes type the app scheduled the alarm with
/// (`AlarmAttributes<BerserkAlarmMetadata>`), so there has to be one
/// definition both processes can import; defined in the UI module, as it was
/// until 2026-10-20, the widget could not name it, and an
/// `ActivityConfiguration` for any other generic argument would simply never
/// match the alarm. The Kit is otherwise "no SwiftUI"; this file imports
/// AlarmKit only, behind the same conditional the scheduler uses, so the macOS
/// slice `swift test` builds never compiles it.
///
/// **Why it carries the course, the title and the due moment.** The Live
/// Activity has nothing else to draw from. `Alarm` exposes no metadata of its
/// own, and `AlarmAttributes.presentation` holds only the alert's title (the
/// assignment's name). The class and the live countdown to the due time are
/// what make the card read as Smooth's, so they travel in the metadata.
///
/// Every field is a plain value, which is all `AlarmMetadata` (`Codable`,
/// `Hashable`, `Sendable`) asks of them. Changing this type's shape changes
/// what an already scheduled alarm decodes to; the alarm id namespace in
/// `BerserkAlarmPlan.alarmID` is versioned for exactly that reason.
@available(iOS 26.0, *)
public struct BerserkAlarmMetadata: AlarmMetadata {
    /// `Assignment.id` of the item the alarm is for.
    public var assignmentID: String
    /// The class as the card shows it (`Assignment.displayCourse`).
    public var course: String
    /// The assignment's name, already trimmed.
    public var title: String
    /// The due moment: the alarm's own time plus ten minutes.
    public var dueAt: Date
    /// The page the stop button opens; nil for manual work and Ed finds.
    public var url: String?

    public init(assignmentID: String, course: String, title: String, dueAt: Date, url: String?) {
        self.assignmentID = assignmentID
        self.course = course
        self.title = title
        self.dueAt = dueAt
        self.url = url
    }
}
#endif

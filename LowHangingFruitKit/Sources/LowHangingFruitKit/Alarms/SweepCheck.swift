import Foundation

/// The notification extension's decision, kept pure so it can be tested on a
/// Mac. Input: the manifest entries near now and whatever Canvas reads the
/// extension managed to make. Output: which alarms and pending requests to
/// remove, and the text to show.
///
/// **Invariant: an unknown never cancels anything.** A missing cookie, a
/// network failure (`reads == nil`), a planner page that did not list the item,
/// an entry with no Canvas id: all of these are unknown, and unknown leaves the
/// alarm armed. The owner's rule is that the Sweeper must never become quieter
/// by accident, so only a read with `cancels == true` for the entry's own
/// Canvas assignment id removes an alarm. The wrong fix is inferring
/// "submitted" from an item's absence in the planner window.
public enum SweepCheck {
    public struct Outcome: Sendable, Equatable {
        public let submitted: [SweepManifest.Entry]
        public let unsubmitted: [SweepManifest.Entry]
        public let unknown: [SweepManifest.Entry]
        /// Alarms of submitted entries only.
        public let alarmIDsToCancel: Set<UUID>
        /// Request ids of submitted entries only, de-duplicated, first-seen order.
        public let requestIDsToRemove: [String]
        /// New notification text, or nil to leave the server's generic text.
        public let body: String?
    }

    /// - Parameters:
    ///   - reads: nil when no read was possible; every entry is then unknown.
    ///   - honourProbe: DEBUG builds pass true so a probe entry counts as
    ///     submitted; release builds pass false and ignore the flag.
    public static func decide(entries: [SweepManifest.Entry], reads: [SubmissionRead]?, honourProbe: Bool) -> Outcome {
        var submitted: [SweepManifest.Entry] = []
        var unsubmitted: [SweepManifest.Entry] = []
        var unknown: [SweepManifest.Entry] = []

        for entry in entries {
            if honourProbe && entry.probe {
                submitted.append(entry)
                continue
            }
            guard let reads, let id = entry.canvasAssignmentID else {
                unknown.append(entry)
                continue
            }
            let mine = reads.filter { $0.assignmentID == id }
            if mine.contains(where: \.cancels) {
                submitted.append(entry)
            } else if mine.contains(where: { $0.verdict == .unsubmitted }) {
                unsubmitted.append(entry)
            } else {
                unknown.append(entry)
            }
        }

        var alarms = Set<UUID>()
        var requests: [String] = []
        var seen = Set<String>()
        for entry in submitted {
            alarms.formUnion(entry.alarmIDs)
            for r in entry.requestIDs where seen.insert(r).inserted { requests.append(r) }
        }

        return Outcome(submitted: submitted, unsubmitted: unsubmitted, unknown: unknown,
                       alarmIDsToCancel: alarms, requestIDsToRemove: requests,
                       body: body(submitted: submitted, unsubmitted: unsubmitted))
    }

    private static func body(submitted: [SweepManifest.Entry], unsubmitted: [SweepManifest.Entry]) -> String? {
        if let first = unsubmitted.first {
            return unsubmitted.count == 1 ? "\(first.title) · not turned in yet"
                                          : "\(unsubmitted.count) not turned in yet"
        }
        if let first = submitted.first {
            return submitted.count == 1 ? "\(first.title) is in · alarm off"
                                        : "\(submitted.count) turned in · alarms off"
        }
        return nil
    }
}

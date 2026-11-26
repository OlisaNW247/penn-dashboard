import Foundation

/// Work the notification extension found handed in while the app was not
/// running. The extension appends here and the app drains it into its ledger at
/// the next launch, so the SwiftData ledger keeps a single writer.
public struct SweepInbox: Codable, Sendable, Equatable {
    public struct Record: Codable, Sendable, Equatable, Hashable {
        public let itemID: String
        public let canvasAssignmentID: String?
        public let at: Date

        public init(itemID: String, canvasAssignmentID: String?, at: Date) {
            self.itemID = itemID
            self.canvasAssignmentID = canvasAssignmentID
            self.at = at
        }
    }

    public let records: [Record]

    public init(records: [Record] = []) { self.records = records }

    /// Adds records, one per item id, keeping the earliest `at` (the first
    /// moment the work was seen handed in). Existing order is kept; new items
    /// follow in the order given.
    public func appending(_ new: [Record]) -> SweepInbox {
        var out = records
        var index: [String: Int] = [:]
        for (i, r) in out.enumerated() where index[r.itemID] == nil { index[r.itemID] = i }
        for r in new {
            if let i = index[r.itemID] {
                if r.at < out[i].at { out[i] = r }
            } else {
                index[r.itemID] = out.count
                out.append(r)
            }
        }
        return SweepInbox(records: out)
    }
}

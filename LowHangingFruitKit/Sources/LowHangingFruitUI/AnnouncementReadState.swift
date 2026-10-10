import Foundation
import LowHangingFruitKit

/// Which announcements the student has already looked at, so the megaphone
/// badge counts only new ones. It used to show the total, which after the
/// first week of term was a number that never went down and so stopped
/// meaning anything.
///
/// Two kinds of thing are tracked under the one key: the extractor's *finds*
/// (ledger rows, ids like `canvasAnnouncement:announcement-42-0`) and the
/// plain announcement *records* (`AnnouncementRecord`, Canvas ids). Record
/// ids are stored with an `announcement:` prefix (`recordKey`) so a record id
/// can never equal an assignment id, whatever shape either takes.
///
/// Preferences tier (`UserDefaults.lhf`), not the ledger: losing it costs
/// nothing but one extra badge. Only the ids of things currently on the page
/// are kept, since only those can be unread: an item that drops off the page
/// takes its id with it, so the stored set never grows past one page.
struct AnnouncementReadState {
    static let key = "seenAnnouncementIDsV1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .lhf) {
        self.defaults = defaults
    }

    var seenIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    private static let recordKeyPrefix = "announcement:"

    /// The stored id for an announcement record.
    static func recordKey(_ announcementID: String) -> String {
        recordKeyPrefix + announcementID
    }

    static func isRecordKey(_ id: String) -> Bool {
        id.hasPrefix(recordKeyPrefix)
    }

    /// Drops every record id and keeps the finds' ids. Used when the log is
    /// cleared, so a reconnect starts from nothing seen.
    func forgetRecords() {
        defaults.set(seenIDs.filter { !Self.isRecordKey($0) }.sorted(), forKey: Self.key)
    }

    /// Called when the sheet opens: everything on the page has now been seen.
    func markAllSeen(_ items: [Assignment], records: [AnnouncementRecord] = []) {
        let ids = items.map(\.id) + records.map { Self.recordKey($0.id) }
        defaults.set(Set(ids).sorted(), forKey: Self.key)
    }

    /// Adds `ids` to the seen set without disturbing the rest, then drops
    /// anything not in `pageIDs`, so the "only what is on the page" bound
    /// still holds. Used when the log is first filled: those records count as
    /// seen, but whether the finds beside them are unread is not decided here.
    func markSeen(_ ids: Set<String>, keepingOnly pageIDs: Set<String>) {
        let kept = seenIDs.union(ids).intersection(pageIDs)
        defaults.set(kept.sorted(), forKey: Self.key)
    }

    // MARK: Pure rules

    static func unread(_ items: [Assignment], seen: Set<String>) -> [Assignment] {
        items.filter { !seen.contains($0.id) }
    }

    static func unreadRecords(_ records: [AnnouncementRecord], seen: Set<String>) -> [AnnouncementRecord] {
        records.filter { !seen.contains(recordKey($0.id)) }
    }

    /// The badge: unread finds plus unread records.
    static func unreadCount(
        finds: [Assignment],
        records: [AnnouncementRecord],
        seen: Set<String>
    ) -> Int {
        unread(finds, seen: seen).count + unreadRecords(records, seen: seen).count
    }

    /// Both kinds of id that were unread, in the form the sheet checks rows
    /// against (`Assignment.id` for a find, `recordKey` for a record).
    static func newIDs(
        finds: [Assignment],
        records: [AnnouncementRecord],
        seen: Set<String>
    ) -> Set<String> {
        Set(unread(finds, seen: seen).map(\.id))
            .union(unreadRecords(records, seen: seen).map { recordKey($0.id) })
    }

    /// The megaphone shows when there is anything to open: it used to need a
    /// find, which is why it was almost never there.
    static func megaphoneVisible(finds: [Assignment], records: [AnnouncementRecord]) -> Bool {
        !finds.isEmpty || !records.isEmpty
    }
}

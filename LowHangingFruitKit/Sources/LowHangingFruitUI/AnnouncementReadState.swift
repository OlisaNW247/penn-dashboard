import Foundation
import LowHangingFruitKit

/// Which announcements the student has already looked at, so the megaphone
/// badge counts only new ones. It used to show the total, which after the
/// first week of term was a number that never went down and so stopped
/// meaning anything.
///
/// Three kinds of thing are tracked under the one key: the extractor's *finds*
/// (ledger rows, ids like `canvasAnnouncement:announcement-42-0`), Canvas
/// announcement *records* (`AnnouncementRecord`, stored with an
/// `announcement:` prefix, `recordKey`), and Ed Discussion rows (stored with
/// an `ed-announcement:` prefix, `edKey`). Each prefix keeps its ids apart
/// from the others and from every assignment id, whatever shape any takes.
///
/// Preferences tier (`UserDefaults.lhf`), not the ledger: losing it costs
/// nothing but one extra badge. The stored set is bounded by what can still
/// be shown: the finds on the page, and every record or Ed row still held on
/// the phone (`markAllSeen(_:records:keeping:)`).
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
    private static let edKeyPrefix = "ed-announcement:"
    /// Set once the Ed rows present at first sight have been marked seen.
    /// Separate from the Canvas log's first fill (which is the log file's
    /// existence), so an install that filled its Canvas log before Ed rows
    /// existed still gets this once.
    static let edSeededKey = "edAnnouncementsSeededV1"

    /// The stored id for an announcement record.
    static func recordKey(_ announcementID: String) -> String {
        recordKeyPrefix + announcementID
    }

    static func isRecordKey(_ id: String) -> Bool {
        id.hasPrefix(recordKeyPrefix)
    }

    /// The stored id for an Ed row. `documentID` is the Ed document's own id
    /// (`ed:{course}:{thread}`).
    static func edKey(_ documentID: String) -> String {
        edKeyPrefix + documentID
    }

    static func isEdKey(_ id: String) -> Bool {
        id.hasPrefix(edKeyPrefix)
    }

    /// The stored id for any row on the sheet's "all announcements" list.
    static func key(for record: AnnouncementRecord) -> String {
        record.isEd ? edKey(record.id) : recordKey(record.id)
    }

    /// Drops every Canvas record id and Ed id, and the Ed-seeded flag, and
    /// keeps the finds' ids. Used when the log is cleared, so a reconnect
    /// starts from nothing seen.
    func forgetRecords() {
        defaults.set(
            seenIDs.filter { !Self.isRecordKey($0) && !Self.isEdKey($0) }.sorted(),
            forKey: Self.key
        )
        defaults.removeObject(forKey: Self.edSeededKey)
    }

    /// Adds `ids` to the seen set and prunes nothing. For callers that can run
    /// before the page is built (launch), where a pruning write would drop
    /// finds that are simply not loaded yet. The set stays bounded because
    /// the next `markAllSeen` prunes it.
    func markSeen(_ ids: Set<String>) {
        defaults.set(seenIDs.union(ids).sorted(), forKey: Self.key)
    }

    var edSeeded: Bool { defaults.bool(forKey: Self.edSeededKey) }

    func markEdSeeded() { defaults.set(true, forKey: Self.edSeededKey) }

    /// Called when the sheet opens: everything on the page has now been seen.
    ///
    /// `known` is every id that could still be shown later: all stored
    /// records and Ed rows, whether or not their class is visible right now.
    /// Ids in `known` that were already seen stay seen. Without it this
    /// replaced the stored set with exactly what was on the page, so hiding a
    /// class, opening the sheet, and showing the class again forgot that its
    /// old posts had been read and badged them all again. Ids outside both
    /// the page and `known` (a post that aged out, a class's documents that
    /// were cleared) are dropped, which is what keeps the set bounded: it
    /// can never hold more than the log, the Ed rows and one page of finds.
    /// Nothing in `known` is *newly* marked seen unless it is on the page, so
    /// a hidden class's unread posts stay unread.
    func markAllSeen(_ items: [Assignment], records: [AnnouncementRecord] = [], keeping known: Set<String> = []) {
        let page = Set(items.map(\.id) + records.map(Self.key(for:)))
        let carried = seenIDs.intersection(known)
        defaults.set(page.union(carried).sorted(), forKey: Self.key)
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
        records.filter { !seen.contains(key(for: $0)) }
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
            .union(unreadRecords(records, seen: seen).map(key(for:)))
    }

    /// The megaphone shows when there is anything to open: it used to need a
    /// find, which is why it was almost never there.
    static func megaphoneVisible(finds: [Assignment], records: [AnnouncementRecord]) -> Bool {
        !finds.isEmpty || !records.isEmpty
    }
}

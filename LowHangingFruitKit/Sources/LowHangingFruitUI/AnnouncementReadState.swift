import Foundation
import LowHangingFruitKit

/// Which announcement finds the student has already looked at, so the
/// megaphone badge counts only new ones. It used to show the total, which
/// after the first week of term was a number that never went down and so
/// stopped meaning anything.
///
/// Preferences tier (`UserDefaults.lhf`), not the ledger: losing it costs
/// nothing but one extra badge. Only the ids of finds currently on the page
/// are kept, since only those can be unread — a find that drops off the page
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

    /// Called when the sheet opens: everything on the page has now been seen.
    func markAllSeen(_ items: [Assignment]) {
        defaults.set(items.map(\.id).sorted(), forKey: Self.key)
    }

    static func unread(_ items: [Assignment], seen: Set<String>) -> [Assignment] {
        items.filter { !seen.contains($0.id) }
    }
}

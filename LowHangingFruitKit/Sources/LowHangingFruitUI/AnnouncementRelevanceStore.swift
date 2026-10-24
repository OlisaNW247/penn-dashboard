import Foundation
import LowHangingFruitKit

/// The server's one judgment per announcement of how long the post stays worth
/// listing (`AnnouncementRelevance`), kept on the phone beside the read state
/// and keyed exactly as the read state keys a row: `AnnouncementReadState
/// .recordKey(id)` for a Canvas post, `.edKey(documentID)` for an Ed post
/// (`AnnouncementReadState.key(for:)`), so the sheet looks a record up by the
/// key it already has.
///
/// Preferences tier (`UserDefaults`, the same domain the read state is given),
/// not the ledger. Losing it costs nothing the student did: a post with no
/// judgment is listed by the plain 7-day rule, and the post is not asked
/// about again (the processed-ids ratchet), so the cost of a lost value is
/// that the post is listed a few days longer than it needed to be. The
/// wrong tier would be the SwiftData ledger, whose rule is "never deletes":
/// this is derived, re-askable text about a post, and it must be bounded and
/// cleared like the log it describes.
///
/// One JSON blob under one key, small by construction: it holds at most one
/// entry per row the log or the Ed list can still show (`prune`), and an entry
/// is a kind and an optional timestamp. Nothing here leaves the phone, and
/// nothing reads it to build a request.
struct AnnouncementRelevanceStore {
    static let key = "announcementRelevanceV1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .lhf) {
        self.defaults = defaults
    }

    /// One stored entry read on its own, so an entry this build cannot read (a
    /// `kind` a later build added) is skipped and the rest survive. A plain
    /// `[String: AnnouncementRelevance]` decode would lose every judgment to
    /// one unknown kind.
    private struct Lossy: Decodable {
        let value: AnnouncementRelevance?
        init(from decoder: Decoder) throws {
            value = try? AnnouncementRelevance(from: decoder)
        }
    }

    /// Everything stored, empty when nothing is or the blob cannot be read.
    var all: [String: AnnouncementRelevance] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([String: Lossy].self, from: data)
        else { return [:] }
        return entries.compactMapValues(\.value)
    }

    /// Replaces the stored set with `entries`. An empty set removes the key.
    func replace(with entries: [String: AnnouncementRelevance]) {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Adds `judgments`, a newer one replacing an older one for the same post,
    /// and leaves the rest. Returns the set now stored.
    @discardableResult
    func merge(_ judgments: [String: AnnouncementRelevance]) -> [String: AnnouncementRelevance] {
        let merged = all.merging(judgments) { _, new in new }
        replace(with: merged)
        return merged
    }

    /// Forgets every judgment. Called with the log (`clearAnnouncementLog`).
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

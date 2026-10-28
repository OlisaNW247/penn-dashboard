import Foundation

/// A copy of the raw bytes of a student-authored blob that could not be read in
/// full, kept before the next save overwrites it.
///
/// `LossyDecoding` makes a bad element cost that element and not the blob, but
/// the survivors are what the store holds from then on, and its next save
/// writes them over the original. For the blobs a student typed in by hand
/// (the per-course preferences, the recurring tasks, the grade overrides) that
/// is a permanent deletion of the unreadable element, with nothing left to
/// recover it from. Often the element is only unreadable to *this* build (a
/// field a newer build wrote), and the student's next update could read it
/// again, so the bytes are worth keeping.
///
/// Stored in the same defaults suite, under `<key>.unreadable`, **once**: an
/// existing copy is never replaced, because a second damaged read is more
/// likely to be the first damage minus a re-save than something more
/// complete. Nothing reads it back; it exists so a person (or a later build
/// that learns to) can. The wrong fix is to refuse to save while any element
/// is unreadable: the student's next edit would silently not stick.
public enum UnreadableBlob {
    public static func slot(for key: String) -> String { key + ".unreadable" }

    /// Keeps `data` under `slot(for: key)` unless a copy is already there.
    /// Returns whether it stored one.
    @discardableResult
    public static func keepRawCopy(of data: Data, forKey key: String, in defaults: UserDefaults) -> Bool {
        let slot = slot(for: key)
        guard defaults.object(forKey: slot) == nil else { return false }
        defaults.set(data, forKey: slot)
        return true
    }

    /// The kept copy, if any.
    public static func rawCopy(forKey key: String, in defaults: UserDefaults) -> Data? {
        defaults.data(forKey: slot(for: key))
    }
}

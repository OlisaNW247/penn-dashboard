import Foundation

/// The rules for what `CloudPrefsMirror` writes where, as pure functions: values
/// in, steps out, no iCloud and no defaults. The mirror itself is inert under
/// `swift test` (it must never reach real iCloud key-value sync), so this is
/// the part of the iCloud preferences path a test can see.
///
/// **What these rules exist to prevent (hardening plan B11, DAT-09).** The
/// mirror used to "seed iCloud with this device's current values" at every
/// launch, and for a key this device had no value for it removed the iCloud
/// copy ("absence is itself meaningful"). Turning sync on for a second device
/// is the case where that is exactly wrong: the second device has no
/// preferences of its own yet, so its launch seed deleted every key the first
/// device had pushed, and the first device then pulled those removals and lost
/// its hidden classes, renames and content decisions. The same launch also
/// overwrote any key both devices held with whichever value happened to be
/// pushed last.
///
/// So there are two rules. A removal is never inferred from absence: the mirror
/// only removes a key through an explicit act (`CloudPrefsMirror.pushRemoval`),
/// and no seed here ever produces one. And the first time sync is on for a
/// device, the two copies of each key are *merged*, so neither device's
/// settings are lost.
enum CloudPrefsMerge {
    /// One write the mirror should perform.
    enum Step {
        /// Put `value` into iCloud.
        case setRemote(key: String, value: Any)
        /// Put `value` into this device's `UserDefaults.lhf`, then let the app
        /// re-read it (the same path a pull from another device takes).
        case setLocal(key: String, value: Any)
    }

    /// What a launch with sync on should do before it does anything else.
    enum LaunchAction: Equatable {
        /// Not the first enable: push this device's present values, as before.
        case seedOnly
        /// First enable, and iCloud already holds values: merge now.
        case mergeNow
        /// First enable, but iCloud's copy has not arrived yet. Pushing now
        /// would write this device's values over data it simply has not
        /// downloaded, which is the overwrite this exists to stop, so wait for
        /// the initial download (or a grace period) and merge then.
        case deferMerge
    }

    static func launchAction(markerSet: Bool, remoteHasAny: Bool) -> LaunchAction {
        if markerSet { return .seedOnly }
        return remoteHasAny ? .mergeNow : .deferMerge
    }

    // MARK: Seeding

    /// The ordinary launch seed: push every value this device has that iCloud
    /// does not already hold equal. **Never a removal**: a key this device has
    /// no value for produces no step, because "I have nothing" is not "delete
    /// yours".
    static func seedSteps(keys: [String], local: [String: Any], remote: [String: Any]) -> [Step] {
        keys.compactMap { key in
            guard let value = local[key], !same(value, remote[key]) else { return nil }
            return .setRemote(key: key, value: value)
        }
    }

    /// The first-enable merge: for each key, combine the two copies
    /// (`merged(local:remote:)`) and write the result to whichever side
    /// differs from it. A device with nothing adopts the other's values and
    /// pushes nothing; a device with values and an empty iCloud pushes them;
    /// two different copies become one on both sides.
    static func mergeSteps(keys: [String], local: [String: Any], remote: [String: Any]) -> [Step] {
        var steps: [Step] = []
        for key in keys {
            guard let value = merged(local: local[key], remote: remote[key]) else { continue }
            if !same(value, remote[key]) { steps.append(.setRemote(key: key, value: value)) }
            if !same(value, local[key]) { steps.append(.setLocal(key: key, value: value)) }
        }
        return steps
    }

    // MARK: Merging one key

    /// The union of two copies of one preference, for the first time they meet.
    ///
    /// - Either side missing: the other.
    /// - Equal: that value.
    /// - Two string lists (hidden and deleted classes): the sorted union. A
    ///   class hidden on either device stays hidden; unhiding it afterwards is
    ///   an ordinary change that pushes the shorter list.
    /// - Two string maps (renames): the union of keys.
    /// - Two JSON objects held as `Data` (the per-class preferences blob, the
    ///   content decisions): the union of their top-level keys, which are class
    ///   codes, so one device's class is never dropped for want of the other
    ///   knowing it.
    /// - Anything else, or a `Data` that is not a JSON object: the iCloud copy.
    ///
    /// **Where both devices hold an entry for the same key, iCloud's wins.**
    /// That is the established copy, and the device doing the merge is the one
    /// that just arrived. It costs the arriving device one setting it had for
    /// that same class ("redo one tap"), where the old overwrite cost the other
    /// device its entire set. There is no timestamp on these entries to do
    /// better, and inventing one would be a schema change for a one-time merge.
    ///
    /// The wrong fix is applying this union at every launch: a union cannot
    /// carry a deletion, so a class unhidden on one device would come straight
    /// back from the other's stale copy. It is for the first meeting only.
    static func merged(local: Any?, remote: Any?) -> Any? {
        guard let local else { return remote }
        guard let remote else { return local }
        if same(local, remote) { return local }

        if let local = local as? [String], let remote = remote as? [String] {
            return Array(Set(local).union(remote)).sorted()
        }
        if let local = local as? [String: String], let remote = remote as? [String: String] {
            return local.merging(remote) { _, remoteValue in remoteValue }
        }
        if let local = local as? Data, let remote = remote as? Data {
            return mergedJSONObjects(local: local, remote: remote) ?? remote
        }
        return remote
    }

    private static func mergedJSONObjects(local: Data, remote: Data) -> Data? {
        guard let local = (try? JSONSerialization.jsonObject(with: local)) as? [String: Any],
              let remote = (try? JSONSerialization.jsonObject(with: remote)) as? [String: Any]
        else { return nil }
        let union = local.merging(remote) { _, remoteValue in remoteValue }
        return try? JSONSerialization.data(withJSONObject: union, options: [.sortedKeys])
    }

    /// Property-list equality, which is what both stores hand back.
    static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return (lhs as AnyObject).isEqual(rhs)
        default: return false
        }
    }
}

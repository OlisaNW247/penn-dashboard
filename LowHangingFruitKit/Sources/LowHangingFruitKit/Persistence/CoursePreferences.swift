import Foundation

/// Everything the student has decided *about* one of their classes.
///
/// **Why one type instead of four maps.** Per-course state used to be four
/// independent `UserDefaults` dictionaries that `AppState` loaded, mutated and
/// re-persisted by hand: `hiddenCourseKeys`, `deletedCourseKeys`,
/// `courseNameOverrides`, `canvasCourseIDsByCode`. Each one cost `AppState` a
/// stored property, a load line, a persist method and a key constant, and every
/// new per-course setting cost another set of all four. v4 needs three more of
/// them — per-course notification muting, per-course recurring-item opt-in, and
/// per-course archival for semester rollover — which would have meant twelve
/// more members on the one file every workstream has to touch. `docs/v4-plan.md`
/// calls that out as the bottleneck (and `docs/v3-integration-handoff.md`
/// records what happened the last time several agents edited it at once).
/// Collapsing the maps into one value per course means a new setting is a new
/// field here and nothing else moves.
///
/// **Keyed by the Canvas course code.** `courseKey` is the same canonical code
/// that class selection, reminders, grades and the deduplicator already key on
/// — deliberately, and it is the reason renaming a class is *cosmetic*. A
/// rename writes `displayName` and leaves `courseKey` alone, so a re-sync
/// cannot orphan the record and every other subsystem keeps finding it.
///
/// **Absence means "all defaults".** A course with no record here behaves
/// exactly like one whose record holds nothing but defaults, which is why
/// `CoursePreferencesStore` prunes a record the moment it returns to default.
/// That is not an optimisation: it is what preserves the old sparse-map
/// semantics, where a course nobody had ever touched simply wasn't a key in any
/// of the four dictionaries.
public struct CoursePreferences: Codable, Sendable, Hashable, Identifiable {

    /// The Canvas course code — the stable identity, never rewritten by a sync.
    public var courseKey: String

    /// The student's own name for the class; `nil` means use the name the feed
    /// supplies. Absorbs `courseNameOverrides`.
    public var displayName: String?

    /// Whether the class appears on the dashboard and feeds notifications.
    /// Absorbs `hiddenCourseKeys` — inverted, because the useful default is
    /// "shown", so a class discovered by a future sync appears without anyone
    /// having to write a record for it.
    public var isVisible: Bool

    /// Whether the student removed the class from their class list. A superset
    /// of hiding: a deleted class is excluded everywhere a hidden one is *and*
    /// disappears from the list itself. Absorbs `deletedCourseKeys`. Purely
    /// local and fully reversible — there is no course on Canvas's side to
    /// delete, so nothing here is destructive.
    public var isDeleted: Bool

    /// The resolved Canvas numeric course id, cached once seen. Absorbs
    /// `canvasCourseIDsByCode`. Ids only ever arrive attached to an ICS item's
    /// URL, so a class with nothing due this week contributes no id — without
    /// this cache such a class silently drops out of Grade Watcher despite
    /// being selected.
    public var canvasCourseID: String?

    /// Per-course mute. `true` by default, so enabling reminders globally does
    /// what a student expects on day one and muting is an explicit act.
    public var notificationsEnabled: Bool

    /// Which lead times this course uses, or `nil` to **inherit the global
    /// setting**.
    ///
    /// The optionality is the load-bearing part of this type and must not be
    /// flattened into a plain `Set`. Two things depend on it:
    ///
    /// - A student can configure the two classes they care about and leave the
    ///   other four alone. With a non-optional set, "left alone" would have to
    ///   be spelled as a copy of the global value taken at some arbitrary
    ///   moment, which then stops tracking the global.
    /// - The global control in Settings stays meaningful. Flatten this and the
    ///   moment per-course settings exist, changing the global affects nothing,
    ///   because every course already holds its own frozen copy.
    ///
    /// An **empty set is not the same as `nil`**: `nil` inherits, `[]` means the
    /// student explicitly wants no lead-time reminders for this course. Both
    /// round-trip through storage distinctly. Resolve with
    /// `effectiveLeadOffsets(global:)` rather than reading this directly.
    public var leadOffsets: Set<LeadOffset>?

    /// Whether readings, check-ins and other recurring non-assignment
    /// obligations notify for this course. Separate from
    /// `notificationsEnabled` because the common request is "keep telling me
    /// about assignments, stop telling me about the weekly reading" — one
    /// switch could not express that.
    public var recurringEnabled: Bool

    /// The term this course was archived into by semester rollover; `nil` means
    /// it is still active. A `Term` rather than a `Bool` so the Done history can
    /// group archived work by semester, and so a rollover that fires twice in
    /// one year is distinguishable from one that fires in consecutive years.
    public var archivedTerm: Term?

    /// Whether the student typed this class in themselves.
    ///
    /// The class list is derived from what the feeds have actually shown, so a
    /// course that hasn't posted an assignment yet contributes no items and
    /// therefore doesn't exist — which in week one of a semester is most of
    /// them. This flag is what lets a hand-added class exist anyway:
    /// `AppState.allCourseCodes()` unions the feed's courses with the courses
    /// carrying it.
    ///
    /// It also has to be *stored*, and that is the second reason it is a field
    /// rather than an inference. A record that says nothing the defaults don't
    /// say is pruned by `commit` (see `isDefault`), so a hand-added class with
    /// no other settings would be dropped the instant it was written. Something
    /// on the record has to say "this course exists because I said so."
    ///
    /// **It is not an identity.** The flag says where the course came from, not
    /// which course it is — `courseKey` does that, and a hand-added class is
    /// keyed by the same canonical `CourseCode` a feed item normalises to. So
    /// when Canvas finally posts for it, the feed's course and this one are the
    /// same key and collapse into one entry with no reconciliation step at all.
    /// Nothing clears the flag at that point and nothing needs to: the class
    /// would now appear on the feed's evidence alone, and the union is a `Set`.
    public var isManuallyAdded: Bool

    public var id: String { courseKey }

    public init(
        courseKey: String,
        displayName: String? = nil,
        isVisible: Bool = true,
        isDeleted: Bool = false,
        canvasCourseID: String? = nil,
        notificationsEnabled: Bool = true,
        leadOffsets: Set<LeadOffset>? = nil,
        recurringEnabled: Bool = true,
        archivedTerm: Term? = nil,
        isManuallyAdded: Bool = false
    ) {
        self.courseKey = courseKey
        self.displayName = displayName
        self.isVisible = isVisible
        self.isDeleted = isDeleted
        self.canvasCourseID = canvasCourseID
        self.notificationsEnabled = notificationsEnabled
        self.leadOffsets = leadOffsets
        self.recurringEnabled = recurringEnabled
        self.archivedTerm = archivedTerm
        self.isManuallyAdded = isManuallyAdded
    }

    // MARK: Derived

    /// Whether this course counts as switched on: shown *and* not deleted.
    /// Mirrors what `AppState.isCourseSelected` has always meant, so callers
    /// reading it get the dashboard's, the scheduler's and Grade Watcher's
    /// shared definition rather than inventing a fourth.
    public var isSelected: Bool { isVisible && !isDeleted }

    /// Whether semester rollover has put this course away.
    public var isArchived: Bool { archivedTerm != nil }

    /// What to show for this class: the student's own name if they set a
    /// non-blank one, otherwise the course code. A whitespace-only override is
    /// treated as no override, so a half-finished edit can never render as an
    /// empty class name.
    public var resolvedName: String {
        guard let custom = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !custom.isEmpty
        else { return courseKey }
        return custom
    }

    /// The lead times that actually apply, given what the global setting
    /// currently is. This is the only correct way to read `leadOffsets` — see
    /// that property's note on why `nil` and `[]` mean different things.
    public func effectiveLeadOffsets(global: Set<LeadOffset>) -> Set<LeadOffset> {
        leadOffsets ?? global
    }

    /// True when this record says nothing the defaults don't already say.
    ///
    /// `CoursePreferencesStore` uses this to drop such a record instead of
    /// storing it. Written against a freshly-defaulted value rather than as a
    /// hand-listed set of comparisons on purpose: a field added later is
    /// covered automatically, where a hand-written list would quietly stop
    /// pruning and start accumulating no-op records.
    public var isDefault: Bool { self == CoursePreferences(courseKey: courseKey) }

    // MARK: Codable

    /// Hand-written on both sides, for one reason: **a field added by a later
    /// build must not destroy an earlier build's stored map.**
    ///
    /// The synthesized `init(from:)` throws on a missing key for any
    /// non-optional property. Because these values are stored as one JSON blob
    /// under a single defaults key, one throw does not lose one course — it
    /// fails the decode of the whole dictionary and resets every course's
    /// settings to default. So every field is read with `decodeIfPresent` and a
    /// default, which is the JSON equivalent of the "always optional or
    /// defaulted" rule `docs/persistence-explained.md` §4 step 1 states for
    /// SwiftData properties, and it exists for the same reason.
    ///
    /// Whoever adds the next field: follow the pattern. `decodeIfPresent ?? x`,
    /// never `decode`.
    private enum CodingKeys: String, CodingKey {
        case courseKey, displayName, isVisible, isDeleted, canvasCourseID
        case notificationsEnabled, leadOffsets, recurringEnabled, archivedTerm
        case isManuallyAdded
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.courseKey = try c.decodeIfPresent(String.self, forKey: .courseKey) ?? ""
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        self.isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        self.canvasCourseID = try c.decodeIfPresent(String.self, forKey: .canvasCourseID)
        self.notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        self.recurringEnabled = try c.decodeIfPresent(Bool.self, forKey: .recurringEnabled) ?? true
        self.archivedTerm = try c.decodeIfPresent(Term.self, forKey: .archivedTerm)
        self.isManuallyAdded = try c.decodeIfPresent(Bool.self, forKey: .isManuallyAdded) ?? false

        // Stored as raw seconds rather than as `Set<LeadOffset>` so that a value
        // written by a future build carrying a lead time this build has never
        // heard of is *dropped*, not thrown on. Decoding the enum directly would
        // fail the whole blob — every course's settings — over one unknown
        // integer. Absent stays absent: that is the inherit-the-global case, and
        // it is distinct from a present-but-empty array.
        if let raw = try c.decodeIfPresent([Int].self, forKey: .leadOffsets) {
            self.leadOffsets = Set(raw.compactMap(LeadOffset.init(rawValue:)))
        } else {
            self.leadOffsets = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(courseKey, forKey: .courseKey)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encode(isVisible, forKey: .isVisible)
        try c.encode(isDeleted, forKey: .isDeleted)
        try c.encodeIfPresent(canvasCourseID, forKey: .canvasCourseID)
        try c.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try c.encode(recurringEnabled, forKey: .recurringEnabled)
        try c.encodeIfPresent(archivedTerm, forKey: .archivedTerm)
        try c.encode(isManuallyAdded, forKey: .isManuallyAdded)
        // Sorted so the encoded blob is byte-stable across runs — `Set`'s
        // iteration order is not. `encodeIfPresent` on the mapped optional keeps
        // `nil` (inherit) written as an absent key rather than as `null`.
        try c.encodeIfPresent(leadOffsets.map { $0.map(\.rawValue).sorted() }, forKey: .leadOffsets)
    }
}

// MARK: - Store

/// The one owner of per-course preferences: loads them, hands them out, and is
/// the only thing that writes them.
///
/// **Which storage tier, and why.** The App Group `UserDefaults` suite, through
/// `UserDefaults.lhf` — tier 2 in `docs/persistence-explained.md` §3. Every
/// field here passes that section's test: if a student lost the lot, they could
/// get it back by tapping a few things. None of it is a record of work done,
/// which is the line that puts something on the SwiftData ledger instead. The
/// App Group suite specifically (rather than the app's private domain) because
/// the widget extension is a separate process and has to honour `isVisible` and
/// `isDeleted` — that requirement is why the shared suite exists at all.
///
/// **One writer.** Every mutation funnels through `commit`, which is the only
/// place that touches the published map or `UserDefaults`. This is deliberate:
/// the failure mode v3 hit (`docs/v3-integration-handoff.md`) was two code
/// paths each persisting half of one fact, so that the app "writes both places
/// or neither" depending on which path ran. A single funnel makes that
/// unrepresentable.
@MainActor
public final class CoursePreferencesStore: ObservableObject {

    /// The single defaults key that replaced four. Not on `SharedDefaults`
    /// alongside the legacy three because nothing outside this type reads it —
    /// those three are public precisely because the widget, in another process,
    /// reads them by name.
    // `nonisolated`: this class is @MainActor, which would isolate even a
    // constant String to the main actor — and `CloudPrefsMirror.mirroredKeys`
    // (a nonisolated static) needs to name this key at type-initialization
    // time. An immutable Sendable constant carries no state to protect.
    public nonisolated static let storageKey = "coursePreferences"

    /// Records for courses that have some non-default setting. A course absent
    /// from this map is not unknown — it is a course sitting on every default.
    @Published public private(set) var byCourseKey: [String: CoursePreferences]

    /// Fired on the main actor immediately *before* `byCourseKey` changes, and
    /// only when something genuinely changed.
    ///
    /// `AppState` forwards it into its own `objectWillChange` so that views
    /// observing `AppState` still re-render when a class is hidden, renamed or
    /// deleted — those reads used to come off `@Published` properties on
    /// `AppState` and now come off computed forwarding accessors, which publish
    /// nothing by themselves. A plain closure rather than a Combine
    /// subscription because both ends are `@MainActor` and Swift 6 would
    /// otherwise need the isolation escape hatch to let a `sink` call back into
    /// an isolated type.
    public var willChange: (@MainActor () -> Void)?

    /// Fired after a genuine change has been committed AND persisted — the
    /// point where the blob under `storageKey` already holds the new state.
    /// `AppState` uses it to push the blob to the iCloud key-value mirror when
    /// sync is on. Not fired by `reloadFromDefaults()` (a pull must not echo
    /// back as a push).
    public var didChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults

    /// `defaults` is injected so tests can drive a scratch suite. The default
    /// is `UserDefaults.lhf`, never `.standard` — see
    /// `docs/persistence-explained.md` §5 on what writing a preference to the
    /// app's private domain does to the widget.
    public init(defaults: UserDefaults = .lhf) {
        self.defaults = defaults
        self.byCourseKey = Self.decodeMap(defaults.data(forKey: Self.storageKey))
    }

    // MARK: Reading

    /// This course's preferences, defaulted if it has no record. Never returns
    /// nil, because "no record" and "all defaults" are the same state.
    public func preferences(for courseKey: String) -> CoursePreferences {
        byCourseKey[courseKey] ?? CoursePreferences(courseKey: courseKey)
    }

    /// Courses that carry a non-default setting, sorted for a stable order.
    /// **Not** the class list — that is still derived from what the feeds have
    /// actually shown. A course can be perfectly real and absent from here.
    public var configuredCourseKeys: [String] { byCourseKey.keys.sorted() }

    public func isVisible(_ courseKey: String) -> Bool { preferences(for: courseKey).isVisible }
    public func isDeleted(_ courseKey: String) -> Bool { preferences(for: courseKey).isDeleted }
    public func isSelected(_ courseKey: String) -> Bool { preferences(for: courseKey).isSelected }
    public func displayName(for courseKey: String) -> String { preferences(for: courseKey).resolvedName }
    public func hasCustomName(_ courseKey: String) -> Bool { preferences(for: courseKey).displayName != nil }
    public func canvasCourseID(for courseKey: String) -> String? {
        preferences(for: courseKey).canvasCourseID
    }
    public func notificationsEnabled(_ courseKey: String) -> Bool {
        preferences(for: courseKey).notificationsEnabled
    }
    public func recurringEnabled(_ courseKey: String) -> Bool {
        preferences(for: courseKey).recurringEnabled
    }
    /// `nil` means this course inherits the global lead times — see
    /// `CoursePreferences.leadOffsets`. Prefer `effectiveLeadOffsets(for:global:)`.
    public func leadOffsets(for courseKey: String) -> Set<LeadOffset>? {
        preferences(for: courseKey).leadOffsets
    }
    public func effectiveLeadOffsets(for courseKey: String, global: Set<LeadOffset>) -> Set<LeadOffset> {
        preferences(for: courseKey).effectiveLeadOffsets(global: global)
    }
    public func archivedTerm(for courseKey: String) -> Term? {
        preferences(for: courseKey).archivedTerm
    }
    public func isArchived(_ courseKey: String) -> Bool { preferences(for: courseKey).isArchived }
    public func isManuallyAdded(_ courseKey: String) -> Bool {
        preferences(for: courseKey).isManuallyAdded
    }

    /// Classes the student typed in themselves, sorted. Unioned into the class
    /// list so a course Canvas hasn't posted for yet still exists in the app.
    public var manuallyAddedCourseKeys: Set<String> {
        Set(byCourseKey.filter(\.value.isManuallyAdded).keys)
    }

    /// Courses a rollover has taken off the roster, as a set.
    public var archivedCourseKeys: Set<String> {
        Set(byCourseKey.filter(\.value.isArchived).keys)
    }

    // MARK: The four legacy projections
    //
    // These exist so `AppState` can keep exposing the names its call sites have
    // always used while holding no per-course state of its own. They are derived
    // on read — there is no second copy to fall out of step.

    /// Courses switched off, in the shape the old `hiddenCourseKeys` set had.
    public var hiddenCourseKeys: Set<String> {
        Set(byCourseKey.filter { !$0.value.isVisible }.keys)
    }

    /// Courses removed from the class list, as the old `deletedCourseKeys` set.
    public var deletedCourseKeys: Set<String> {
        Set(byCourseKey.filter(\.value.isDeleted).keys)
    }

    /// Custom class names, as the old `courseNameOverrides` dictionary.
    public var courseNameOverrides: [String: String] {
        byCourseKey.compactMapValues(\.displayName)
    }

    /// Resolved Canvas ids, as the old `canvasCourseIDsByCode` dictionary.
    public var canvasCourseIDsByCode: [String: String] {
        byCourseKey.compactMapValues(\.canvasCourseID)
    }

    // MARK: Writing

    /// The general mutation. Reads the course's current preferences (defaulted
    /// if it has none), hands them to `mutate`, and stores the result. Returns
    /// whether anything actually changed.
    ///
    /// `courseKey` is restored after the closure runs: a mutation is allowed to
    /// change what a course's settings *are*, never which course they belong
    /// to. Re-keying through here would leave a record filed under one key
    /// claiming to be another, which every read would then disagree about.
    @discardableResult
    public func update(
        _ courseKey: String,
        _ mutate: (inout CoursePreferences) -> Void
    ) -> Bool {
        var value = preferences(for: courseKey)
        mutate(&value)
        value.courseKey = courseKey
        return commit([courseKey: value])
    }

    public func setVisible(_ courseKey: String, _ isVisible: Bool) {
        update(courseKey) { $0.isVisible = isVisible }
    }

    public func setDeleted(_ courseKey: String, _ isDeleted: Bool) {
        update(courseKey) { $0.isDeleted = isDeleted }
    }

    /// Sets or clears the cosmetic rename. A name that is blank after trimming,
    /// or that is just the course code again, clears the override rather than
    /// storing a redundant one — so "rename it back" and "clear the field" reach
    /// the same state, and neither leaves a record behind that pruning would
    /// otherwise have to special-case.
    public func setDisplayName(_ courseKey: String, to newName: String?) {
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(courseKey) {
            $0.displayName = (trimmed?.isEmpty == false && trimmed != courseKey) ? trimmed : nil
        }
    }

    public func setCanvasCourseID(_ courseKey: String, _ id: String?) {
        update(courseKey) { $0.canvasCourseID = id }
    }

    public func setNotificationsEnabled(_ courseKey: String, _ enabled: Bool) {
        update(courseKey) { $0.notificationsEnabled = enabled }
    }

    /// Pass `nil` to put this course back on the global lead times.
    public func setLeadOffsets(_ courseKey: String, _ offsets: Set<LeadOffset>?) {
        update(courseKey) { $0.leadOffsets = offsets }
    }

    public func setRecurringEnabled(_ courseKey: String, _ enabled: Bool) {
        update(courseKey) { $0.recurringEnabled = enabled }
    }

    /// Files the course under a term (rollover) or brings it back (`nil`).
    public func setArchivedTerm(_ courseKey: String, _ term: Term?) {
        update(courseKey) { $0.archivedTerm = term }
    }

    /// Marks a class as one the student added by hand, or clears the mark.
    ///
    /// Clearing is what "remove this class I added" means: the record falls back
    /// to defaults and `commit` prunes it, so the course leaves the list exactly
    /// as if it had never been typed — unless a feed has since started posting
    /// for it, in which case it stays, because it is a real class now and
    /// forgetting who first mentioned it changes nothing.
    public func setManuallyAdded(_ courseKey: String, _ isManuallyAdded: Bool) {
        update(courseKey) { $0.isManuallyAdded = isManuallyAdded }
    }

    /// Folds a batch of newly-resolved Canvas ids in, in one write.
    ///
    /// A **merge, not a replace**: a course absent from `map` keeps whatever id
    /// it already had. That is the entire reason the cache exists — a sync in a
    /// quiet week resolves ids for only the courses that happened to have
    /// something due, and replacing would drop the rest out of Grade Watcher.
    ///
    /// Returns whether anything changed, which callers rely on: the caller in
    /// `AppState` runs on every dashboard rebuild and must not publish a change
    /// when there isn't one.
    @discardableResult
    public func mergeCanvasCourseIDs(_ map: [String: String]) -> Bool {
        var updates: [String: CoursePreferences] = [:]
        for (courseKey, id) in map where preferences(for: courseKey).canvasCourseID != id {
            var value = preferences(for: courseKey)
            value.canvasCourseID = id
            updates[courseKey] = value
        }
        return commit(updates)
    }

    /// Forgets every resolved Canvas id. Used when disconnecting the Canvas
    /// account, where keeping ids would point a later reconnect at courses that
    /// may no longer belong to this student.
    @discardableResult
    public func clearAllCanvasCourseIDs() -> Bool {
        var updates: [String: CoursePreferences] = [:]
        for (courseKey, value) in byCourseKey where value.canvasCourseID != nil {
            var next = value
            next.canvasCourseID = nil
            updates[courseKey] = next
        }
        return commit(updates)
    }

    /// Drops every record. Only for tests and a full local reset — this is the
    /// student's own configuration, not a cache.
    @discardableResult
    public func removeAll() -> Bool {
        guard !byCourseKey.isEmpty else { return false }
        willChange?()
        byCourseKey = [:]
        persist()
        didChange?()
        return true
    }

    // MARK: The single funnel

    /// Applies a batch of records and persists if — and only if — the result
    /// differs from what is already held.
    ///
    /// The equality guard is not a micro-optimisation. `AppState`'s Canvas-id
    /// cache is refreshed from `rebuildDashboardItems`, which runs on every
    /// sync and every completion toggle; publishing a change each time would
    /// re-render the dashboard for nothing, and the original code guarded
    /// against exactly this for exactly this reason.
    @discardableResult
    private func commit(_ updates: [String: CoursePreferences]) -> Bool {
        guard !updates.isEmpty else { return false }
        var next = byCourseKey
        for (courseKey, value) in updates {
            // A record that says nothing the defaults don't say is not stored.
            // See `CoursePreferences.isDefault`.
            if value.isDefault {
                next.removeValue(forKey: courseKey)
            } else {
                next[courseKey] = value
            }
        }
        guard next != byCourseKey else { return false }
        willChange?()
        byCourseKey = next
        persist()
        didChange?()
        return true
    }

    /// Re-reads the persisted blob, replacing the in-memory map.
    ///
    /// Exists for exactly one caller: `AppState.reloadMirroredPreferences`,
    /// after an external iCloud pull has written a fresh blob under
    /// `storageKey` (see `CloudPrefsMirror`). Whole-value last-writer-wins —
    /// whatever is on disk is simply this device's new truth. Fires
    /// `willChange` but deliberately NOT `didChange`: a pull must not be
    /// pushed straight back to the cloud, or two devices would echo each
    /// other's writes forever.
    public func reloadFromDefaults() {
        let next = Self.decodeMap(defaults.data(forKey: Self.storageKey))
        guard next != byCourseKey else { return }
        willChange?()
        byCourseKey = next
        // Persist only the legacy projection: the blob itself was just read
        // from these defaults, but the widget-visible keys are derived output
        // and must track it (see `writeLegacyProjection`).
        persist()
    }

    /// Re-keys every record through `transform` — the migration for state
    /// stored under raw registrar strings before `CourseCode.parse` learned to
    /// clean them (spaced separators, cross-listing prefixes).
    ///
    /// Collision rule: when two old keys normalize to the same clean code,
    /// the record whose old key was ALREADY normalized wins when one exists,
    /// else whichever is encountered first — the variants were always the same
    /// course, and landing on the wrong record either way is one tap to fix.
    public func normalizeCourseKeys(_ transform: (String) -> String) {
        var next: [String: CoursePreferences] = [:]
        var winnerWasAlreadyNormalized: Set<String> = []
        for (oldKey, value) in byCourseKey {
            let newKey = transform(oldKey)
            let isAlreadyNormalized = newKey == oldKey
            if next[newKey] == nil
                || (isAlreadyNormalized && !winnerWasAlreadyNormalized.contains(newKey)) {
                var rekeyed = value
                rekeyed.courseKey = newKey
                next[newKey] = rekeyed
                if isAlreadyNormalized { winnerWasAlreadyNormalized.insert(newKey) }
            }
        }
        guard next != byCourseKey else { return }
        willChange?()
        byCourseKey = next
        persist()
        didChange?()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(byCourseKey) {
            defaults.set(data, forKey: Self.storageKey)
        }
        writeLegacyProjection()
    }

    /// Keeps the four superseded keys written, as a derived projection.
    ///
    /// **This is not the "writes both places" bug.** There is one writer
    /// (`commit` → `persist`), one canonical record (the `coursePreferences`
    /// blob), and these four keys are never read back by the app — nothing in
    /// `AppState` consults them any more. They are an *output*. Two things
    /// still need them to exist:
    ///
    /// - `LedgerWidgetReader` reads `hiddenCourseKeys`, `deletedCourseKeys` and
    ///   `courseNameOverrides` by name, from another process, to avoid the
    ///   widget advertising a class the student already hid or deleted. Stop
    ///   writing them and that regression comes back silently.
    /// - `docs/persistence-explained.md` §4 step 3 says not to delete legacy
    ///   keys, so a downgrade can still read its data. Keeping them *current*
    ///   rather than merely undeleted is the strongest version of that: a
    ///   downgraded build sees the student's real settings, not a snapshot from
    ///   whenever they upgraded.
    ///
    /// It also makes the migration a fixed point. `importLegacyCourseState`
    /// reads these four keys, so if they always describe the canonical store,
    /// re-running the migration folds the store into itself and changes
    /// nothing — idempotence by construction rather than by a pile of
    /// don't-clobber rules.
    private func writeLegacyProjection() {
        defaults.set(hiddenCourseKeys.sorted(), forKey: SharedDefaults.hiddenCoursesKey)
        defaults.set(deletedCourseKeys.sorted(), forKey: SharedDefaults.deletedCoursesKey)
        defaults.set(courseNameOverrides, forKey: SharedDefaults.courseNameOverridesKey)
        defaults.set(canvasCourseIDsByCode, forKey: Self.legacyCanvasCourseIDsKey)
    }

    // MARK: Decoding

    /// Pure and `nonisolated` so a future widget/extension read can share it
    /// without needing the main actor — the reason `LedgerWidgetReader` can't
    /// simply construct this store today.
    public nonisolated static func decodeMap(_ data: Data?) -> [String: CoursePreferences] {
        guard let data,
              let map = try? JSONDecoder().decode([String: CoursePreferences].self, from: data)
        else { return [:] }
        return map
    }

    // MARK: - Migration off the four legacy keys

    /// The key the resolved-Canvas-id map used to live under. The other three
    /// are on `SharedDefaults`, which declares them public because the widget
    /// reads them; this one was only ever read by `AppState`, so it stays here
    /// with the code that supersedes it.
    static let legacyCanvasCourseIDsKey = "canvasCourseIDsByCode"

    /// Folds the four legacy per-course maps into `CoursePreferences` records.
    ///
    /// Called by `LegacyStateMigration`, which owns the version gate — this
    /// function owns only the folding, the same split as
    /// `AssignmentStore.importLegacyCompletions`. Returns how many course
    /// records it actually *changed*, which is deliberately not the number it
    /// looked at: on a second run that number is zero, which is what makes the
    /// migration summary a usable idempotence assertion.
    ///
    /// **Safe to run twice**, and not by luck: the store re-writes all four keys
    /// as a derived projection on every save (`writeLegacyProjection`), so on a
    /// second run they already describe exactly what is stored, the fold
    /// produces identical records, and `commit`'s equality guard makes it a
    /// no-op. That matters because the version marker is itself a UserDefaults
    /// value and a device restored from backup can present a stale one.
    ///
    /// **The legacy keys are not deleted.** See `writeLegacyProjection`.
    @discardableResult
    public static func importLegacyCourseState(in defaults: UserDefaults) -> Int {
        let store = CoursePreferencesStore(defaults: defaults)

        let hidden = Set(defaults.stringArray(forKey: SharedDefaults.hiddenCoursesKey) ?? [])
        let deleted = Set(defaults.stringArray(forKey: SharedDefaults.deletedCoursesKey) ?? [])
        let names = defaults
            .dictionary(forKey: SharedDefaults.courseNameOverridesKey) as? [String: String] ?? [:]
        let canvasIDs = defaults
            .dictionary(forKey: legacyCanvasCourseIDsKey) as? [String: String] ?? [:]

        // One record per course mentioned by any of the four maps. Built from
        // the *stored* record rather than from a fresh default so that a field
        // this migration knows nothing about — anything a later v4 workstream
        // adds — is carried through untouched instead of being reset.
        let touched = hidden.union(deleted).union(names.keys).union(canvasIDs.keys)
        var updates: [String: CoursePreferences] = [:]
        for courseKey in touched {
            var value = store.preferences(for: courseKey)
            if hidden.contains(courseKey) { value.isVisible = false }
            if deleted.contains(courseKey) { value.isDeleted = true }
            if let name = names[courseKey] { value.displayName = name }
            if let id = canvasIDs[courseKey] { value.canvasCourseID = id }
            // Only report — and only carry — records the fold actually moves.
            guard value != store.preferences(for: courseKey) else { continue }
            updates[courseKey] = value
        }

        store.commit(updates)
        return updates.count
    }
}

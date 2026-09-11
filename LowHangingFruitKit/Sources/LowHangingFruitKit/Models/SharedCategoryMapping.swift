import Foundation

/// The client's decoded form of `map-categories`'s pooled mapping — one
/// course's answer to "which Canvas assignment groups, and which stray
/// items, feed which of the syllabus's grading categories," shared across
/// every classmate enrolled in the same course rather than re-derived per
/// device. `GradeCategoryMapBuilder.fromSharedMapping` is the only thing
/// that turns this into a `GradeCategoryMap`; this type itself is just the
/// wire-shaped result, kept tolerant to decode the same way
/// `CourseProfileWire` is (see that type's header): the server's own
/// `_shared/categoryMap.ts` sanitizer already enforces "every id is one the
/// request actually listed" and "a name the model invents is dropped,"
/// but a client that trusted a stored jsonb row to always carry every
/// field forever is exactly the mistake CLAUDE.md's jsonb-drift trap
/// describes — a row written before some future field existed would
/// otherwise fail this whole decode instead of degrading to "no data for
/// the new field yet."
public struct SharedCategoryMapping: Codable, Sendable, Hashable {
    /// One category as the server's shared mapping states it. `name` is
    /// always one of the course's `gradingWeights[].name` values verbatim
    /// (the server drops any name it invents, category and all) —
    /// `GradeCategoryMapBuilder.fromSharedMapping` re-checks that against
    /// the device's own syllabus scheme anyway rather than trusting the
    /// server's word for it, the same "re-validate, don't just trust the
    /// jsonb" discipline as the enclosing type.
    public struct Category: Codable, Sendable, Hashable {
        public let name: String
        public let canvasGroupIDs: [String]
        public let itemIDs: [String]
        public let expectedCount: Int?

        public init(
            name: String,
            canvasGroupIDs: [String] = [],
            itemIDs: [String] = [],
            expectedCount: Int? = nil
        ) {
            self.name = name
            self.canvasGroupIDs = canvasGroupIDs
            self.itemIDs = itemIDs
            self.expectedCount = expectedCount
        }

        private enum CodingKeys: String, CodingKey {
            case name, canvasGroupIDs, itemIDs, expectedCount
        }

        /// Missing `canvasGroupIDs`/`itemIDs` decode as empty rather than
        /// failing the whole category — the same tolerance
        /// `CourseProfileWire.init(from:)` extends to its own arrays, for
        /// the same reason: a legacy row from before a field existed must
        /// not sink everything that shares its container.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            canvasGroupIDs = try container.decodeIfPresent([String].self, forKey: .canvasGroupIDs) ?? []
            itemIDs = try container.decodeIfPresent([String].self, forKey: .itemIDs) ?? []
            expectedCount = try container.decodeIfPresent(Int.self, forKey: .expectedCount)
        }
    }

    public let categories: [Category]
    public let excludedItemIDs: [String]
    public let reasons: [String: String]
    public let extractedAt: Date?
    /// The SERVER's own `structureHash`, carried verbatim for diagnostics
    /// only — never compared against `MapCategoriesRequest.localStructureHash`
    /// (see that property's header for why the two are namespaced apart).
    public let structureHash: String

    public init(
        categories: [Category] = [],
        excludedItemIDs: [String] = [],
        reasons: [String: String] = [:],
        extractedAt: Date? = nil,
        structureHash: String = ""
    ) {
        self.categories = categories
        self.excludedItemIDs = excludedItemIDs
        self.reasons = reasons
        self.extractedAt = extractedAt
        self.structureHash = structureHash
    }

    private enum CodingKeys: String, CodingKey {
        case categories, excludedItemIDs, reasons, extractedAt, structureHash
    }

    /// Tolerant like `CourseProfileWire.init(from:)`: missing
    /// `categories`/`excludedItemIDs`/`reasons` decode as empty, a missing
    /// or unparseable `extractedAt` decodes as `nil` rather than failing the
    /// decode, and a missing `structureHash` decodes as `""`. `extractedAt`
    /// is read as a string and handed to `BackendJSON.parseDate` — the same
    /// fractional-or-not ISO 8601 acceptance every other date on this wire
    /// gets — rather than trusted to `Date`'s own decode strategy, because
    /// this type is decoded standalone (inside `MapCategoriesResponse`, not
    /// through `BackendJSON.decoder()`'s custom date strategy) and needs its
    /// own parsing exactly like `CourseProfileWire.extractedAt` does.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = try container.decodeIfPresent([Category].self, forKey: .categories) ?? []
        excludedItemIDs = try container.decodeIfPresent([String].self, forKey: .excludedItemIDs) ?? []
        reasons = try container.decodeIfPresent([String: String].self, forKey: .reasons) ?? [:]
        structureHash = try container.decodeIfPresent(String.self, forKey: .structureHash) ?? ""
        if let raw = try container.decodeIfPresent(String.self, forKey: .extractedAt) {
            extractedAt = BackendJSON.parseDate(raw)
        } else {
            extractedAt = nil
        }
    }

    /// Round-trips through the app's own local cache (this is never sent
    /// back to the server): `extractedAt` is written with the same
    /// formatter family `BackendJSON.encoder()` uses for every other date on
    /// this wire — `ISO8601DateFormatter` with fractional seconds — so a
    /// value decoded back through `init(from:)` compares equal.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(categories, forKey: .categories)
        try container.encode(excludedItemIDs, forKey: .excludedItemIDs)
        try container.encode(reasons, forKey: .reasons)
        try container.encode(structureHash, forKey: .structureHash)
        if let extractedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: extractedAt), forKey: .extractedAt)
        } else {
            try container.encodeNil(forKey: .extractedAt)
        }
    }
}

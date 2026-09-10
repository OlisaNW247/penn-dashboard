import Foundation

/// One grading category as the syllabus states it — "Problem Sets … 30%".
///
/// This is what the professor wrote, not what Canvas has. It becomes real only
/// after the user maps it onto a Canvas assignment group (`SyllabusMatcher`)
/// and confirms it.
public struct SyllabusCategory: Sendable, Hashable, Codable, Identifiable {
    /// Normalized name — stable across re-parses of the same syllabus, so
    /// confirmed mappings survive a re-import.
    public let id: String
    /// The name exactly as written, for display.
    public let name: String
    /// Weight in percent, as written.
    public let weightPercent: Double
    /// "the lowest two problem sets are dropped" → 2. 0 when unstated.
    public let dropLowest: Int
    /// "there will be 10 problem sets" → 10. Nil when unstated. Canvas often
    /// doesn't list work the professor hasn't created yet, so this is the only
    /// way the app can know how much is still coming.
    public let expectedItemCount: Int?
    /// The source line this was read from, shown in the review sheet so the
    /// user can check the parse rather than trust it.
    public let evidence: String

    public init(
        id: String,
        name: String,
        weightPercent: Double,
        dropLowest: Int = 0,
        expectedItemCount: Int? = nil,
        evidence: String = ""
    ) {
        self.id = id
        self.name = name
        self.weightPercent = weightPercent
        self.dropLowest = dropLowest
        self.expectedItemCount = expectedItemCount
        self.evidence = evidence
    }
}

/// A parsed grading scheme: the weight table, optional letter cutoffs, and how
/// much we trust the parse.
public struct SyllabusGradingScheme: Sendable, Hashable, Codable {
    public enum Confidence: String, Sendable, Codable, Hashable {
        /// Weights sum to 100 (± 0.5) across ≥ 2 categories. Pre-checked in
        /// the review sheet — still confirmed by the user, never auto-applied.
        case high
        /// Weights sum within the accepted 90–110 band but not to 100.
        /// Presented unchecked: something is probably missing.
        case medium
    }

    /// Categories with weights **as written** (not normalized).
    public let categories: [SyllabusCategory]
    /// Letter-grade cutoffs, when the syllabus published a table.
    public let cutoffs: GradeCutoffs?
    /// The syllabus mentions a curve or instructor discretion — cutoffs and
    /// projections may not hold, and the UI must say so.
    public let mentionsCurve: Bool
    public let confidence: Confidence
    /// Sum of the weights as written — shown in the review sheet ("these add
    /// up to 95%") so a partial parse is visible rather than silently scaled.
    public let rawWeightSum: Double

    public init(
        categories: [SyllabusCategory],
        cutoffs: GradeCutoffs? = nil,
        mentionsCurve: Bool = false,
        confidence: Confidence,
        rawWeightSum: Double
    ) {
        self.categories = categories
        self.cutoffs = cutoffs
        self.mentionsCurve = mentionsCurve
        self.confidence = confidence
        self.rawWeightSum = rawWeightSum
    }

    /// Weights rescaled to sum to 100. Canvas doesn't require its own weights
    /// to sum to 100 either, and the engine renormalizes regardless — this is
    /// for display and for handing clean numbers to the weight editor.
    public var normalizedCategories: [SyllabusCategory] {
        guard rawWeightSum > 0 else { return categories }
        let scale = 100 / rawWeightSum
        return categories.map {
            SyllabusCategory(
                id: $0.id,
                name: $0.name,
                weightPercent: ($0.weightPercent * scale * 100).rounded() / 100,
                dropLowest: $0.dropLowest,
                expectedItemCount: $0.expectedItemCount,
                evidence: $0.evidence
            )
        }
    }
}

extension SyllabusGradingScheme {
    /// Turns the backend's syllabus extraction (`CourseGradingProfile`) into
    /// the same on-device proposal type `SyllabusParser.parse` produces, so
    /// every downstream consumer — the review sheet, `SyllabusMatcher`,
    /// confirmation — treats a server-suggested scheme exactly like a
    /// locally parsed one and needs no separate code path.
    ///
    /// Applies the identical honesty gate `SyllabusParser.parse` applies to
    /// its own output (`SyllabusParser.acceptedSumRange`, fewer than two
    /// categories): the whole reason that gate exists is that a grading
    /// scheme's weights sum to 100, so a parse — deterministic or, now,
    /// server-side — that doesn't land in the accepted band is almost
    /// certainly wrong and must not be offered to the student as if it were
    /// trustworthy. The server doing the extraction instead of the device
    /// changes *where* the parse happens, not the app's promise about what
    /// it will present as fact versus what it makes the student confirm —
    /// so this function refuses exactly what `SyllabusParser.parse` would
    /// have refused, rather than trusting the server's own math.
    public static func from(profile: CourseGradingProfile) -> SyllabusGradingScheme? {
        guard profile.weights.count >= 2 else { return nil }
        let sum = profile.weights.reduce(0) { $0 + $1.percent }
        guard SyllabusParser.acceptedSumRange.contains(sum) else { return nil }

        let categories = profile.weights.map { weight in
            SyllabusCategory(
                id: TitleNormalizer.categoryKey(weight.name),
                name: weight.name,
                weightPercent: weight.percent,
                dropLowest: weight.dropLowest ?? 0,
                expectedItemCount: weight.expectedCount,
                evidence: "from the syllabus, read by locust's server"
            )
        }

        return SyllabusGradingScheme(
            categories: categories,
            cutoffs: nil,
            mentionsCurve: false,
            confidence: abs(sum - 100) <= SyllabusParser.exactSumTolerance ? .high : .medium,
            rawWeightSum: sum
        )
    }
}

/// Where a syllabus's text came from — shown in the report so the user knows
/// which document the numbers are keyed to.
public enum SyllabusSource: String, Sendable, Codable, Hashable {
    case canvasSyllabusPage
    case canvasFile
    case canvasPage
    case pasted
    case importedFile
    /// A scheme built from `CourseGradingProfile` — the backend's own
    /// syllabus extraction, shared across everyone enrolled in the course
    /// rather than parsed fresh on this device (`SyllabusGradingScheme.from
    /// (profile:)`).
    case sharedProfile

    public var label: String {
        switch self {
        case .canvasSyllabusPage: return "Canvas syllabus"
        case .canvasFile:         return "Canvas file"
        case .canvasPage:         return "Canvas page"
        case .pasted:             return "Pasted text"
        case .importedFile:       return "Imported file"
        case .sharedProfile:      return "the syllabus, as read by locust's server"
        }
    }
}

/// A syllabus the user has attached to a watched course: the accepted scheme
/// plus where it came from and when.
public struct AttachedSyllabus: Sendable, Hashable, Codable {
    public let scheme: SyllabusGradingScheme
    public let source: SyllabusSource
    /// Display name of the document (file name, page title) when there is one.
    public let documentName: String?
    public let attachedAt: Date

    public init(
        scheme: SyllabusGradingScheme,
        source: SyllabusSource,
        documentName: String? = nil,
        attachedAt: Date = Date()
    ) {
        self.scheme = scheme
        self.source = source
        self.documentName = documentName
        self.attachedAt = attachedAt
    }
}

/// A candidate syllabus document found on Canvas, before parsing.
public struct SyllabusCandidate: Sendable, Hashable, Identifiable {
    public let id: String
    public let source: SyllabusSource
    public let name: String
    /// Plain text, already extracted (HTML stripped / PDF flattened).
    public let text: String
    /// Outbound links the HTML carried before it was flattened. The
    /// syllabus page is the single most likely place an instructor points
    /// at an external course website, and stripping to text used to throw
    /// that pointer away; `CourseKnowledgeCollector` forwards these to the
    /// backend's website discovery. Empty for PDF and pasted sources.
    public let links: [HTMLLink]

    public init(id: String, source: SyllabusSource, name: String, text: String, links: [HTMLLink] = []) {
        self.id = id
        self.source = source
        self.name = name
        self.text = text
        self.links = links
    }
}

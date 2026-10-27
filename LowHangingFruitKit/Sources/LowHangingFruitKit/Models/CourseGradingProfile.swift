import Foundation

/// A grading scheme the backend extracted from a course's syllabus text —
/// the server-side counterpart to `SyllabusParser.parse`, run once per
/// course (not per student) and shared through the sync manifest so a
/// student never waits on their own device to re-derive what the syllabus
/// already said. Kept as a distinct type from `SyllabusGradingScheme`
/// rather than reusing it directly: this is the *wire-shaped* extraction
/// (weights, components, when it was made), and `SyllabusGradingScheme.from
/// (profile:)` (Syllabus/SyllabusModels.swift) is the one place that turns
/// it into the on-device proposal type, applying the same honesty gate
/// `SyllabusParser` applies to its own parses — nothing here is offered to
/// the student as fact until it passes that gate.
public struct CourseGradingProfile: Sendable, Hashable, Codable, Identifiable {
    /// One grading category as the server's extraction read it — "Problem
    /// Sets … 30%, drop the lowest two, 10 expected."
    public struct Weight: Sendable, Hashable, Codable {
        public let name: String
        public let percent: Double
        /// "there will be 10 problem sets" — nil when the syllabus didn't
        /// state a count, same meaning as `SyllabusCategory.expectedItemCount`.
        public let expectedCount: Int?
        /// "the lowest two are dropped" — nil (not 0) when the syllabus
        /// said nothing about drops, so `SyllabusGradingScheme.from(profile:)`
        /// can distinguish "server didn't see a drop rule" from "server saw
        /// zero drops," even though both currently map to the same `0` on
        /// `SyllabusCategory.dropLowest`.
        public let dropLowest: Int?

        public init(name: String, percent: Double, expectedCount: Int? = nil, dropLowest: Int? = nil) {
            self.name = name
            self.percent = percent
            self.expectedCount = expectedCount
            self.dropLowest = dropLowest
        }
    }

    /// One graded component of the course as the server's extraction
    /// identified it — distinct from `CatalogComponent`, which is the
    /// registrar's section-level view; this is the syllabus's own
    /// description of what it's grading ("Lab", "pass/fail") and is what
    /// `GradeSiteExclusion` reads to decide a Canvas site doesn't carry the
    /// course grade.
    public struct Component: Sendable, Hashable, Codable {
        public let name: String
        /// The syllabus's own words for how this component is graded, e.g.
        /// "Pass/Fail" or "Satisfactory/Unsatisfactory" — free text, not a
        /// closed enum, because the server is quoting the syllabus, not
        /// classifying it; `GradeSiteExclusion` does the classifying against
        /// this string with its own pattern.
        public let gradingBasis: String?
        public let creditUnits: Double?

        public init(name: String, gradingBasis: String? = nil, creditUnits: Double? = nil) {
            self.name = name
            self.gradingBasis = gradingBasis
            self.creditUnits = creditUnits
        }
    }

    /// One exam the server's extraction read out of the syllabus and course
    /// pages: "Midterm 1", the day it said, and the line it read it from.
    /// `SyllabusExamRows` turns each dated one into an exam card, ahead of
    /// what the phone reads out of the same text on its own.
    public struct ExamDate: Sendable, Hashable, Codable {
        public let name: String
        /// The calendar day as `YYYY-MM-DD`, or nil when the server gave none
        /// or something that is not a real day ("October 23", "2026-02-30").
        /// Kept as the day it names and not as a `Date`: a `Date` needs a time
        /// zone, which this type has no business choosing, and a
        /// `CourseGradingProfile` is persisted, so a stored instant would
        /// shift with the zone the phone was in when it was read. The caller's
        /// calendar turns it into a moment (`day(in:)`).
        public let date: String?
        /// The extraction's own words for it ("Midterm 1: Thursday, October
        /// 23"), so a person can be shown why the app believes this. Empty
        /// when the server sent none.
        public let text: String

        public init(name: String, date: String? = nil, text: String = "") {
            self.name = name
            self.date = date.flatMap(Self.normalizedDay(_:))
            self.text = text
        }

        private enum CodingKeys: String, CodingKey {
            case name, date, text
        }

        /// Tolerant on purpose, like `CourseProfileWire`: `name` is the only
        /// field an exam cannot do without, a `date` of the wrong type or
        /// shape is "undated" and not an error, and a missing `text` is empty.
        /// A throw here would be caught per element by the array decode in
        /// `CourseGradingProfile`/`CourseProfileWire` and cost one exam, never
        /// the profile around it.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            let rawDate = try? container.decodeIfPresent(String.self, forKey: .date)
            date = rawDate.flatMap(Self.normalizedDay(_:))
            text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        }

        /// The start of the day this exam is on, in `calendar`, or nil when it
        /// has no date. Nothing here invents a time: the caller stores a
        /// syllabus exam with no time of day at the end of its day.
        public func day(in calendar: Calendar) -> Date? {
            // The day is a Gregorian `YYYY-MM-DD`; read in a Buddhist calendar
            // "2026" is the year 1483 CE (`Calendar.gregorian(matching:)`).
            let calendar = Calendar.gregorian(matching: calendar)
            guard let date, let day = Self.dayParts(of: date),
                  let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
            else { return nil }
            // `Calendar` rolls a day the month does not have into the next
            // month instead of failing; `dayParts(of:)` has already refused those,
            // but the calendar passed here may disagree about a year.
            let back = calendar.dateComponents([.year, .month, .day], from: start)
            guard back.year == day.year, back.month == day.month, back.day == day.day else { return nil }
            return calendar.startOfDay(for: start)
        }

        /// `YYYY-MM-DD` for a real calendar day, otherwise nil. A date-time
        /// (`2026-10-23T18:00:00-04:00`) is cut to its day, the same rule the
        /// server applies (`isoDayOf` in `_shared/profile.ts`), so a build
        /// talking to an older server that sent a longer string agrees with
        /// one talking to the current one.
        static func normalizedDay(_ raw: String) -> String? {
            guard let day = dayParts(of: raw) else { return nil }
            return String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
        }

        private static func dayParts(of raw: String) -> (year: Int, month: Int, day: Int)? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 10 else { return nil }
            let head = trimmed.prefix(10)
            let fields = head.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
                  fields.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
                  let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2])
            else { return nil }
            let rest = trimmed.dropFirst(10)
            guard rest.isEmpty || rest.first == "T" || rest.first == " " else { return nil }

            // A fixed calendar, so whether the day exists never depends on the
            // phone's region or time zone.
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            guard let probe = gregorian.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            let back = gregorian.dateComponents([.year, .month, .day], from: probe)
            guard back.year == year, back.month == month, back.day == day else { return nil }
            return (year, month, day)
        }
    }

    public var id: String { courseID }

    public let courseID: String
    public let weights: [Weight]
    public let components: [Component]
    /// The exams the server read out of this course's syllabus and pages, in
    /// the order it listed them; undated ones included, because the entry is
    /// true even when the date is not usable (the exam pass ignores them).
    ///
    /// Added after `weights`, and a profile is persisted inside
    /// `CourseKnowledgeBase`, so every profile already on a student's disk
    /// predates it. `init(from:)` reads it with `decodeIfPresent`: a key that
    /// has never existed must not fail the decode, which would drop the whole
    /// knowledge base back to `.empty` (see `CourseKnowledgeBase.catalog`).
    public let examDates: [ExamDate]
    /// When the server ran this extraction — shown so a stale profile
    /// (superseded by a newer syllabus) can eventually be told apart from a
    /// fresh one, though nothing in this Kit compares it yet.
    public let extractedAt: Date

    public init(
        courseID: String,
        weights: [Weight],
        components: [Component],
        extractedAt: Date,
        examDates: [ExamDate] = []
    ) {
        self.courseID = courseID
        self.weights = weights
        self.components = components
        self.extractedAt = extractedAt
        self.examDates = examDates
    }

    private enum CodingKeys: String, CodingKey {
        case courseID, weights, components, extractedAt, examDates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courseID = try container.decode(String.self, forKey: .courseID)
        weights = try container.decode([Weight].self, forKey: .weights)
        components = try container.decode([Component].self, forKey: .components)
        extractedAt = try container.decode(Date.self, forKey: .extractedAt)
        examDates = container.decodeLossyArray(ExamDate.self, forKey: .examDates)
    }
}

extension KeyedDecodingContainer {
    /// An array whose bad elements are skipped instead of failing the array.
    /// Absent, `null`, or not an array at all reads as empty.
    ///
    /// The ordinary `decodeIfPresent([T].self)` throws for the whole array when
    /// one element is malformed, and the arrays this is used for ride inside a
    /// response (`SyncManifestResponse.profiles`) or a file
    /// (`CourseKnowledgeBase`) that loses everything else in it when it
    /// throws. An exam the server wrote oddly is worth one exam, not the
    /// manifest.
    ///
    /// A failed `decode` leaves an unkeyed container on the same element, so
    /// the loop steps over it by decoding it as something that cannot fail;
    /// the `currentIndex` check is the guard against a container that does not
    /// move, which would otherwise be an endless loop.
    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard contains(key), (try? decodeNil(forKey: key)) == false,
              var list = try? nestedUnkeyedContainer(forKey: key)
        else { return [] }
        var elements: [T] = []
        while !list.isAtEnd {
            let before = list.currentIndex
            if let element = try? list.decode(T.self) {
                elements.append(element)
            } else {
                _ = try? list.decode(DiscardedElement.self)
            }
            if list.currentIndex == before { break }
        }
        return elements
    }
}

/// Decodes from anything and keeps nothing: `decodeLossyArray`'s way of
/// moving past an element it could not read.
private struct DiscardedElement: Decodable {
    init(from decoder: Decoder) throws {}
}

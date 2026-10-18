import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("CourseGradingProfile wire decoding")
struct CourseGradingProfileTests {
    // MARK: - CourseProfileWire

    @Test("CourseProfileWire decodes a full profile and converts to CourseGradingProfile")
    func decodesFullProfile() throws {
        let json = """
        {"courseID":"1234","gradingWeights":[
           {"name":"Problem Sets","percent":30,"expectedCount":10,"dropLowest":2},
           {"name":"Final","percent":70}
         ],
         "components":[{"name":"Lab","gradingBasis":"Pass/Fail","creditUnits":0}],
         "extractedAt":"2026-09-07T14:03:00Z"}
        """
        let wire = try BackendJSON.decoder().decode(CourseProfileWire.self, from: Data(json.utf8))
        let profile = try #require(wire.profile())
        #expect(profile.courseID == "1234")
        #expect(profile.weights.count == 2)
        #expect(profile.weights.first?.name == "Problem Sets")
        #expect(profile.weights.first?.expectedCount == 10)
        #expect(profile.weights.first?.dropLowest == 2)
        #expect(profile.weights.last?.dropLowest == nil)
        #expect(profile.components.first?.gradingBasis == "Pass/Fail")
        #expect(profile.components.first?.creditUnits == 0)
    }

    @Test("CourseProfileWire decodes missing optional weight/component fields")
    func decodesMissingOptionalFields() throws {
        let json = """
        {"courseID":"1234","gradingWeights":[{"name":"Only","percent":100}],
         "components":[{"name":"Lecture"}],
         "extractedAt":"2026-09-07T14:03:00.500Z"}
        """
        let wire = try BackendJSON.decoder().decode(CourseProfileWire.self, from: Data(json.utf8))
        #expect(wire.gradingWeights.first?.expectedCount == nil)
        #expect(wire.gradingWeights.first?.dropLowest == nil)
        #expect(wire.components.first?.gradingBasis == nil)
        #expect(wire.components.first?.creditUnits == nil)
        #expect(wire.profile() != nil)
    }

    @Test("CourseProfileWire decodes a row missing both arrays as empty rather than failing")
    func decodesMissingArraysAsEmpty() throws {
        let json = #"{"courseID":"1234","extractedAt":"2026-09-07T14:03:00Z"}"#
        let wire = try BackendJSON.decoder().decode(CourseProfileWire.self, from: Data(json.utf8))
        #expect(wire.gradingWeights.isEmpty)
        #expect(wire.components.isEmpty)
        #expect(wire.profile()?.weights.isEmpty == true)
    }

    @Test("CourseProfileWire.profile() returns nil for an unparseable extractedAt")
    func profileNilOnUnparseableDate() throws {
        let json = #"{"courseID":"1234","gradingWeights":[],"components":[],"extractedAt":"not a date"}"#
        let wire = try BackendJSON.decoder().decode(CourseProfileWire.self, from: Data(json.utf8))
        #expect(wire.profile() == nil)
    }

    // MARK: - SyncManifestResponse.profiles

    @Test("SyncManifestResponse decodes a missing profiles key to empty")
    func manifestResponseDefaultsProfilesToEmpty() throws {
        let response = try BackendJSON.decoder().decode(SyncManifestResponse.self, from: Data("{}".utf8))
        #expect(response.profiles.isEmpty)
    }

    @Test("SyncManifestResponse decodes a present profiles array")
    func manifestResponseDecodesProfiles() throws {
        let json = """
        {"profiles":[{"courseID":"1234","gradingWeights":[{"name":"Final","percent":100}],"components":[],"extractedAt":"2026-09-07T14:03:00Z"}]}
        """
        let response = try BackendJSON.decoder().decode(SyncManifestResponse.self, from: Data(json.utf8))
        #expect(response.profiles.count == 1)
        #expect(response.profiles.first?.courseID == "1234")
    }

    @Test("SyncManifestResponse drops an individual profile with an unparseable extractedAt rather than failing the whole decode")
    func manifestResponseDropsUnparseableProfile() throws {
        let json = """
        {"profiles":[
           {"courseID":"good","gradingWeights":[],"components":[],"extractedAt":"2026-09-07T14:03:00Z"},
           {"courseID":"bad","gradingWeights":[],"components":[],"extractedAt":"not a date"}
         ]}
        """
        let response = try BackendJSON.decoder().decode(SyncManifestResponse.self, from: Data(json.utf8))
        #expect(response.profiles.count == 1)
        #expect(response.profiles.first?.courseID == "good")
    }

    // MARK: - examDates (the exams the server read out of the syllabus)

    @Test("CourseProfileWire decodes examDates, dated and undated, and a date-time is cut to its day")
    func decodesExamDates() throws {
        let json = """
        {"courseID":"1234","gradingWeights":[],"components":[],
         "examDates":[
           {"name":"Midterm 1","date":"2026-10-23","text":"Midterm 1: Thursday, October 23"},
           {"name":"Midterm 2","date":"2026-11-20T19:00:00-05:00","text":"Midterm 2, 7 pm"},
           {"name":"Final Exam","text":"set by the registrar"}
         ],
         "extractedAt":"2026-09-07T14:03:00Z"}
        """
        let wire = try BackendJSON.decoder().decode(CourseProfileWire.self, from: Data(json.utf8))
        #expect(wire.examDates.map(\.name) == ["Midterm 1", "Midterm 2", "Final Exam"])
        #expect(wire.examDates.map(\.date) == ["2026-10-23", "2026-11-20", nil])
        #expect(wire.examDates.first?.text == "Midterm 1: Thursday, October 23")
        let profile = try #require(wire.profile())
        #expect(profile.examDates == wire.examDates)
    }

    @Test("an older server's profile, with no examDates key, still decodes and has no exams")
    func decodesWithoutExamDates() throws {
        let json = #"{"courseID":"1234","gradingWeights":[{"name":"Final","percent":100}],"components":[],"extractedAt":"2026-09-07T14:03:00Z"}"#
        let wire = try BackendJSON.decoder().decode(CourseProfileWire.self, from: Data(json.utf8))
        #expect(wire.examDates.isEmpty)
        let profile = try #require(wire.profile())
        #expect(profile.examDates.isEmpty)
        #expect(profile.weights.count == 1)
    }

    @Test("examDates that is not an array, or null, reads as no exams and costs the profile nothing else")
    func examDatesWrongShape() throws {
        for value in [#""Midterm Oct 23""#, #"{"name":"Midterm","date":"2026-10-23","text":"t"}"#, "7", "null"] {
            let json = #"{"courseID":"1234","gradingWeights":[{"name":"Final","percent":100}],"components":[],"examDates":"# + value + #","extractedAt":"2026-09-07T14:03:00Z"}"#
            let wire = try BackendJSON.decoder().decode(CourseProfileWire.self, from: Data(json.utf8))
            #expect(wire.examDates.isEmpty, "\(value)")
            #expect(wire.gradingWeights.count == 1, "\(value)")
        }
    }

    @Test("a malformed exam is dropped on its own: the good ones, the weights and the rest of the manifest are kept")
    func malformedExamsAreDroppedOneByOne() throws {
        let json = """
        {"download":[],"catalog":[],"profiles":[
          {"courseID":"1234","gradingWeights":[{"name":"Final","percent":100}],"components":[],
           "examDates":[
             "Midterm Oct 23", null, 42, {"date":"2026-10-23","text":"no name"}, {"name":7,"text":"t"},
             {"name":"Midterm 1","date":"2026-10-23","text":"ok"},
             {"name":"Midterm 2","date":"October 30","text":"not a day"},
             {"name":"Midterm 3","date":20261101,"text":"not a string"},
             {"name":"Final Exam","date":"2026-12-15"}
           ],
           "extractedAt":"2026-09-07T14:03:00Z"},
          {"courseID":"5678","gradingWeights":[],"components":[],"extractedAt":"2026-09-07T14:03:00Z"}
        ]}
        """
        let response = try BackendJSON.decoder().decode(SyncManifestResponse.self, from: Data(json.utf8))
        #expect(response.profiles.map(\.courseID) == ["1234", "5678"])
        let exams = try #require(response.profiles.first).examDates
        #expect(exams.map(\.name) == ["Midterm 1", "Midterm 2", "Midterm 3", "Final Exam"])
        #expect(exams.map(\.date) == ["2026-10-23", nil, nil, "2026-12-15"])
        #expect(exams.last?.text == "")
        #expect(response.profiles.first?.weights.count == 1)
    }

    @Test("a day is a day: real calendar days are kept, anything else is undated, and a time of day is never invented")
    func examDateNormalization() throws {
        let valid: [(String, String)] = [
            ("2026-10-23", "2026-10-23"), ("  2026-10-23 ", "2026-10-23"), ("2028-02-29", "2028-02-29"),
            ("2026-10-23T18:00:00-04:00", "2026-10-23"), ("2026-10-23 18:00", "2026-10-23"),
        ]
        for (raw, expected) in valid {
            #expect(CourseGradingProfile.ExamDate(name: "Midterm 1", date: raw).date == expected, "\(raw)")
        }
        for raw in ["", "TBD", "October 23", "10/23/2026", "2026-1-5", "20261023", "2026-02-29", "2026-02-30", "2026-13-01", "2026-00-10", "2026-10-23x"] {
            #expect(CourseGradingProfile.ExamDate(name: "Midterm 1", date: raw).date == nil, "\(raw)")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let day = try #require(CourseGradingProfile.ExamDate(name: "Midterm 1", date: "2026-10-23").day(in: calendar))
        #expect(day == calendar.date(from: DateComponents(year: 2026, month: 10, day: 23)))
        #expect(CourseGradingProfile.ExamDate(name: "Final Exam").day(in: calendar) == nil)
    }

    @Test("a knowledge base saved before examDates existed still loads, with its profiles and no exams")
    func legacyKnowledgeBaseLoads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lhf-profile-exams-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        {"courses":[],"documents":[],"catalog":[],
         "gradingProfiles":[{"courseID":"1234","weights":[{"name":"Final","percent":100}],
                             "components":[],"extractedAt":"2026-09-07T14:03:00Z"}]}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("course-knowledge.json"))

        let loaded = CourseKnowledgeStore(directory: directory).load()
        let profile = try #require(loaded.gradingProfile(forCourseID: "1234"))
        #expect(profile.weights.count == 1)
        #expect(profile.examDates.isEmpty)
    }

    @Test("exam dates survive the knowledge base's save and load, and a newer profile replaces the older one for the course")
    func examDatesPersist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lhf-profile-exams-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CourseKnowledgeStore(directory: directory)

        let extractedAt = Date(timeIntervalSince1970: 1_788_000_000)
        var knowledge = CourseKnowledgeBase()
        knowledge.mergeGradingProfiles([CourseGradingProfile(
            courseID: "1234", weights: [], components: [], extractedAt: extractedAt,
            examDates: [CourseGradingProfile.ExamDate(name: "Midterm 1", date: "2026-10-23", text: "t")]
        )])
        try store.save(knowledge)
        #expect(store.load().gradingProfile(forCourseID: "1234")?.examDates == [
            CourseGradingProfile.ExamDate(name: "Midterm 1", date: "2026-10-23", text: "t"),
        ])

        knowledge.mergeGradingProfiles([CourseGradingProfile(
            courseID: "1234", weights: [], components: [], extractedAt: extractedAt,
            examDates: [CourseGradingProfile.ExamDate(name: "Midterm 1", date: "2026-10-30")]
        )])
        #expect(knowledge.gradingProfile(forCourseID: "1234")?.examDates.first?.date == "2026-10-30")
    }
}

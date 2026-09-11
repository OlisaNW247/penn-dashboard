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
}

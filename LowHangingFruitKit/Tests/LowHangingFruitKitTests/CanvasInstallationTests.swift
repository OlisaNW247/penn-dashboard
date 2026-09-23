import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Canvas installation")
struct CanvasInstallationTests {
    @Test("verified directory has unique ids and HTTPS origins")
    func verifiedDirectoryIsValid() {
        let schools = CanvasInstallation.verifiedSchools
        #expect(Set(schools.map(\.id)).count == schools.count)
        #expect(schools.allSatisfy { $0.baseURL.scheme == "https" })
        #expect(schools.allSatisfy { !$0.host.isEmpty })
        #expect(schools.allSatisfy { $0.isVerified })
    }

    @Test("custom address accepts a hostname without a scheme and removes paths")
    func normalizesCustomAddress() {
        let installation = CanvasInstallation.custom(address: "canvas.example.edu/login/saml")
        #expect(installation?.baseURL.absoluteString == "https://canvas.example.edu")
        #expect(installation?.loginURL.absoluteString == "https://canvas.example.edu")
        #expect(installation?.name == "canvas.example.edu")
        #expect(installation?.isVerified == false)
    }

    @Test("custom address rejects unsafe or non-HTTPS destinations", arguments: [
        "http://canvas.example.edu",
        "https://localhost",
        "https://127.0.0.1",
        "not a host",
        "",
    ])
    func rejectsUnsafeAddress(_ address: String) {
        #expect(CanvasInstallation.custom(address: address) == nil)
    }

    @Test("Cornell separates its login gateway from its Canvas API origin")
    func cornellUsesSeparateGateway() {
        let cornell = CanvasInstallation.verifiedSchools.first { $0.id == "cornell" }
        #expect(cornell?.loginURL.host == "login.canvas.cornell.edu")
        #expect(cornell?.baseURL.host == "canvas.cornell.edu")
    }
}

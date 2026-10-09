import Testing
import Foundation
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Reconnect pane")
struct ReconnectPaneTests {
    @Test("Penn's pre-login purge keeps Canvas and the IdP but not Duo")
    func pennPreLoginPurgeExcludesDuo() {
        let hints = CanvasInstallation.penn.preLoginPurgeDomainHints
        #expect(hints.contains("instructure"))
        #expect(hints.contains("upenn.edu"))
        #expect(!hints.contains { $0.contains("duosecurity") })
        #expect(CanvasInstallation.penn.websiteDataDomainHints.contains("duosecurity"))
    }

    @Test("every verified school loses only the Duo hint from the pre-login purge")
    func everySchoolLosesOnlyDuo() {
        for school in CanvasInstallation.verifiedSchools {
            let full = school.websiteDataDomainHints
            let pre = school.preLoginPurgeDomainHints
            #expect(full.contains("duosecurity"), "\(school.id) disconnect must still wipe Duo")
            #expect(!pre.contains { $0.contains("duosecurity") }, "\(school.id)")
            for hint in full where !hint.contains("duosecurity") {
                #expect(pre.contains(hint), "\(school.id) lost \(hint)")
            }
        }
    }

    @Test("initial phase rule")
    func initialPhaseRule() {
        #expect(OnboardingView.initialPhase(for: .canvas, hasChosenSchool: true) == .canvasLogin)
        #expect(OnboardingView.initialPhase(for: .canvas, hasChosenSchool: false) == .schoolSelection)
        #expect(OnboardingView.initialPhase(for: .gradescope, hasChosenSchool: true) == .gradescopeLogin)
        #expect(OnboardingView.initialPhase(for: .gradescope, hasChosenSchool: false) == .gradescopeLogin)
        #expect(OnboardingView.initialPhase(for: .full, hasChosenSchool: true) == .schoolSelection)
        #expect(OnboardingView.initialPhase(for: .full, hasChosenSchool: false) == .schoolSelection)
    }
}

import Foundation
import Testing
@testable import LowHangingFruitUI

@Suite("Assistant presentation and Canvas routing")
struct AssistantPresentationTests {
    @Test("Greetings cycle and use the local weekday")
    func greetings() {
        let date = Date(timeIntervalSince1970: 1_704_067_200) // Monday UTC, Sunday in LA.
        #expect(AssistantPresentation.greeting(index: 0, date: date) == "Ask about classes")
        #expect(AssistantPresentation.greeting(index: 1, date: date) == "How can I help?")
        #expect(AssistantPresentation.greeting(index: 2, date: date, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "Happy Sunday")
    }

    @Test("Answers remove bold styling while retaining text, paragraphs and source links")
    func outputFormatting() {
        let result = AssistantPresentation.answer("**Friday**\n\nSee [the syllabus](https://canvas.example.edu/courses/12/pages/syllabus).")
        #expect(String(result.characters).contains("Friday\n\nSee the syllabus."))
        #expect(!result.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(result.runs.contains { $0.link?.host == "canvas.example.edu" })
    }

    @Test("Canvas app links retain the school, route, query and fragment")
    func canvasLink() {
        let url = URL(string: "https://canvas.umich.edu/courses/12/assignments/34?module_item_id=56#submission")!
        #expect(CanvasAppLink.appURL(for: url)?.absoluteString == "canvas-courses://canvas.umich.edu/courses/12/assignments/34?module_item_id=56#submission")
        for value in ["http://canvas.example.edu/courses/12", "https://user:password@canvas.example.edu/courses/12", "https://canvas.example.edu/login", "https://canvas.example.edu/courses/not-an-id"] {
            #expect(CanvasAppLink.appURL(for: URL(string: value)!) == nil)
        }
    }

    @Test("Late or repeated Canvas callbacks cannot send Gradescope or reminders backward")
    func onboardingCallbacks() {
        #expect(OnboardingView.acceptsCanvasConnection(in: .canvasLogin, alreadyReady: false))
        #expect(!OnboardingView.acceptsCanvasConnection(in: .canvasLogin, alreadyReady: true))
        for phase in [OnboardingView.Phase.canvasConnected, .gradescopeChoice, .gradescopeLogin, .reminders] {
            #expect(!OnboardingView.acceptsCanvasConnection(in: phase, alreadyReady: false))
        }
    }
}

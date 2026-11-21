import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitUI

/// The one notification for a missed Duo push.
@Suite("Duo wait notice")
struct DuoWaitNoticeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func post(
        awaiting: Bool = true,
        expired: Bool = true,
        latchAge: TimeInterval? = 61 * 60,
        posted: Date? = nil,
        fixture: Bool = false
    ) -> Bool {
        DuoWaitNotice.shouldPost(
            awaitingDuo: awaiting,
            sessionExpired: expired,
            latchedAt: latchAge.map { now.addingTimeInterval(-$0) },
            now: now,
            postedForLatchAt: posted,
            fixtureData: fixture
        )
    }

    @Test("an hour after the latch, once")
    func truthTable() {
        #expect(post())
        #expect(!post(awaiting: false))
        #expect(!post(expired: false))
        #expect(!post(latchAge: 30 * 60))
        #expect(!post(latchAge: nil))
        #expect(!post(latchAge: -60))
        #expect(!post(fixture: true))
    }

    @Test("exactly an hour after the latch is enough")
    func exactlyAnHour() { #expect(post(latchAge: 3600)) }

    @Test("posted for this latch: no; a new latch date: yes")
    func oncePerLatch() {
        let latch = now.addingTimeInterval(-61 * 60)
        #expect(!post(posted: latch))
        #expect(post(posted: latch.addingTimeInterval(-86_400)))
    }

    @Test("the request is pinned")
    func request() {
        let request = DuoWaitNotice.request()
        #expect(request.identifier == "duo:wait")
        #expect(request.content.title == "Smooth")
        #expect(request.content.body == "sign in to canvas to keep smooth updated")
        #expect(request.content.categoryIdentifier.isEmpty)
        #expect(request.trigger == nil)
        #expect(request.content.interruptionLevel == .active)
        #expect(DuoWaitNotice.isDuoIdentifier(request.identifier))
        #expect(!DuoWaitNotice.isDuoIdentifier("due:abc:1"))
    }

    @Test("the reminder pass spares duo: like ambassador:")
    func sparing() throws {
        let code = try HardeningSourceScan.uiCode("BerserkAlarmDelivery.swift")
        let body = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func applyNotifications(", in: code)
        #expect(body.contains("AmbassadorReminders.isAmbassadorIdentifier"))
        #expect(body.contains("DuoWaitNotice.isDuoIdentifier"))
    }

    @Test("the refresh wake posts it, the push wake does not")
    func wakes() throws {
        let code = try HardeningSourceScan.uiCode("BackgroundRefresh.swift")
        let push = try HardeningSourceScan.body(ofFunctionDeclaredWith: "private static func runPush() async -> Bool", in: code)
        #expect(!push.contains("DuoWait"))
        let run = try HardeningSourceScan.body(ofFunctionDeclaredWith: "private static func run() async", in: code)
        #expect(run.contains("postDuoWaitNoticeIfDue(scheduler: scheduler)"))
    }

    @Test("a tap routes by prefix to the sign-in cover; clearing the latch clears the record")
    func routing() throws {
        let router = try HardeningSourceScan.uiCode("NotificationResponseRouter.swift")
        #expect(router.contains("DuoWaitNotice.isDuoIdentifier(response.notification.request.identifier)"))
        #expect(router.contains("DuoWaitNoticeInbox.shared.noteTapped()"))
        let view = try HardeningSourceScan.uiCode("ContentView.swift")
        #expect(view.contains("state.restartOnboarding(for: .canvas)"))
        #expect(view.contains("duoNotice.consume()"))
        let app = try HardeningSourceScan.uiCode("AppState.swift")
        let setter = try HardeningSourceScan.body(ofFunctionDeclaredWith: "private func setAutoLoginAwaitingDuo(", in: app)
        #expect(setter.contains("DuoWaitNotice.latchCleared()"))
    }

    @Test("the status line wording is exact")
    func wording() throws {
        let view = try HardeningSourceScan.uiCode("ContentView.swift")
        #expect(view.contains(#"statusLineLabel("duo needs you \u{00B7} tap to finish \u{2014} every 30 days, smooth can get signed out")"#))
        #expect(!view.contains(#"tap to finish")"#))
    }
}

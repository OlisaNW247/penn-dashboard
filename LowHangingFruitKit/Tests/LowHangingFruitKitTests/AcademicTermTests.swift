import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Academic term")
struct AcademicTermTests {

    private let calendar = Calendar.current

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    @Test("late August is the fall term, which started mid-August")
    func fallTerm() {
        let term = AcademicTerm.current(on: date(2025, 8, 28), calendar: calendar)
        #expect(term.season == .fall)
        #expect(term.year == 2025)
        #expect(term.start == date(2025, 8, 15, 0))
    }

    @Test("early August is still the summer term")
    func summerTerm() {
        let term = AcademicTerm.current(on: date(2025, 8, 1), calendar: calendar)
        #expect(term.season == .summer)
        #expect(term.start == date(2025, 5, 20, 0))
    }

    @Test("the new year starts the spring term, so the fall is over")
    func springTerm() {
        let term = AcademicTerm.current(on: date(2026, 1, 5), calendar: calendar)
        #expect(term.season == .spring)
        #expect(term.year == 2026)
        #expect(term.start == date(2026, 1, 1, 0))
    }

    @Test("December is still the fall term")
    func decemberIsFall() {
        let term = AcademicTerm.current(on: date(2025, 12, 20), calendar: calendar)
        #expect(term.season == .fall)
        #expect(term.year == 2025)
    }

    @Test("boundaries switch terms on the day, not around it")
    func boundariesAreExact() {
        #expect(AcademicTerm.current(on: date(2025, 5, 19), calendar: calendar).season == .spring)
        #expect(AcademicTerm.current(on: date(2025, 5, 20), calendar: calendar).season == .summer)
        #expect(AcademicTerm.current(on: date(2025, 8, 14), calendar: calendar).season == .summer)
        #expect(AcademicTerm.current(on: date(2025, 8, 15), calendar: calendar).season == .fall)
    }

    @Test("the term start is never in the future")
    func startNeverAfterTheDate() {
        for month in 1...12 {
            let now = date(2025, month, 10)
            #expect(AcademicTerm.current(on: now, calendar: calendar).start <= now)
        }
    }
}

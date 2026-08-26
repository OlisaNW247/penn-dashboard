import SwiftUI
import LowHangingFruitKit

/// One-time explanation-and-ask sheet for a course whose Canvas presence the
/// dashboard isn't already representing — either it posts dated readings/
/// events with nothing to submit, or it's silent on the calendar entirely but
/// a probe found Modules readings (docs/READINGS_COURSES_PLAN.md). Presented
/// at most once per app-open, off `AppState.pendingCourseNudge`; `.normal`
/// and `.unknownSilent` profiles never reach this sheet (`AppState
/// .queueNudgeIfNeeded` filters them out via `isActionable`), so their branch
/// below is a harmless fallback rather than something this view asserts on.
struct CourseNudgeSheet: View {
    let report: CourseProfileReport
    let onInclude: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "book")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.v2SpineBlue)

            Text(report.displayName)
                .font(.lhfSans(15, weight: .semibold))
                .foregroundStyle(Color.v2Ink)
                .multilineTextAlignment(.center)

            Text(explanation)
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Button(action: onInclude) {
                Text("Add to my list")
                    .font(.lhfSans(13, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)

            Button(action: onSkip) {
                Text("Not for this class")
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
                    .underline()
            }
            .buttonStyle(.plain)

            Text("You can change this anytime in Settings.")
                .font(.lhfSans(10.5))
                .foregroundStyle(Color.v2CourseCode)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(Color.v2Bg)
        .lhfSheetTheme()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var explanation: String {
        switch report.profile {
        case let .readingsOnCalendar(eventCount, latestDate):
            return Self.readingsCopy(count: eventCount, latestDate: latestDate)
        case let .silent(moduleReadingCount):
            return Self.silentCopy(count: moduleReadingCount)
        case .normal, .unknownSilent:
            return Self.silentCopy(count: nil)
        }
    }

    private static func readingsCopy(count: Int, latestDate: Date?) -> String {
        let itemWord = count == 1 ? "item" : "items"
        var text = "This class posts readings and events on its calendar, but nothing to turn in. LHF found \(count) \(itemWord)"
        if let latestDate {
            text += ", through \(latestDate.formatted(.dateTime.month(.abbreviated).day()))"
        }
        text += "."
        return text
    }

    private static func silentCopy(count: Int?) -> String {
        let n = count ?? 0
        let itemWord = n == 1 ? "item" : "items"
        return "This class doesn't put anything on your calendar. LHF found \(n) \(itemWord) in its Modules pages."
    }
}

#if DEBUG
#Preview("Readings on calendar") {
    Color.v2Bg
        .sheet(isPresented: .constant(true)) {
            CourseNudgeSheet(
                report: CourseProfileReport(
                    courseKey: "FNAR 2200",
                    canvasCourseID: "12345",
                    displayName: "FNAR 2200",
                    profile: .readingsOnCalendar(eventCount: 12, latestDate: Date()),
                    fingerprint: "readings:10"
                ),
                onInclude: {},
                onSkip: {}
            )
            .environmentObject(AppState())
        }
}

#Preview("Silent course") {
    Color.v2Bg
        .sheet(isPresented: .constant(true)) {
            CourseNudgeSheet(
                report: CourseProfileReport(
                    courseKey: "PHIL 1000",
                    canvasCourseID: "67890",
                    displayName: "PHIL 1000",
                    profile: .silent(moduleReadingCount: 22),
                    fingerprint: "silent:20"
                ),
                onInclude: {},
                onSkip: {}
            )
            .environmentObject(AppState())
        }
}
#endif

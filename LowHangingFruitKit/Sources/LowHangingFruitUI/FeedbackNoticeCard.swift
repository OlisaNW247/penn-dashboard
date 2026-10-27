import SwiftUI
import LowHangingFruitKit

/// The feedback form's address when the manifest has not supplied one.
/// Profile → feedback opens this unless the live notice carries its own link.
///
/// **Nothing is ever appended to this address**: no query parameters, no
/// prefilled fields, nothing about the student, the install or the build. The
/// form is anonymous from the app's side, which is what lets the privacy
/// policy say nothing about the student leaves the phone through it.
enum FeedbackForm {
    static let defaultURL = URL(
        string: "https://docs.google.com/forms/d/e/1FAIpQLScZJ4BBXicAOFYSbCkHGcM5kWcDD8OXSSWtkK64kSSUO4WcJQ/viewform"
    )!
}

/// What `RootCore` hands the dashboard when a feedback card should show. An
/// environment value rather than an `@EnvironmentObject`, so `ContentView`
/// (built bare by previews and tests) needs nothing to exist: no context,
/// no card.
struct FeedbackNoticeContext {
    let notice: FeedbackNotice
    /// Opens the form and marks the card handled.
    let open: () -> Void
    /// Marks the card handled without opening anything.
    let dismiss: () -> Void
}

private struct FeedbackNoticeContextKey: EnvironmentKey {
    static var defaultValue: FeedbackNoticeContext? { nil }
}

private struct FeedbackFormURLKey: EnvironmentKey {
    static var defaultValue: URL { FeedbackForm.defaultURL }
}

extension EnvironmentValues {
    var feedbackNoticeContext: FeedbackNoticeContext? {
        get { self[FeedbackNoticeContextKey.self] }
        set { self[FeedbackNoticeContextKey.self] = newValue }
    }

    /// The address Profile's "send feedback" row opens. The default is
    /// `FeedbackForm.defaultURL`, so Profile works with nothing set.
    var feedbackFormURL: URL {
        get { self[FeedbackFormURLKey.self] }
        set { self[FeedbackFormURLKey.self] = newValue }
    }
}

/// The one-time card under the dashboard header, drawn like
/// `UpdateAvailableBanner`. The body is one button (title and subtitle read
/// as its label); the x beside it is a second one. Persistence of "handled"
/// lives in `UpdateGateStore`; this view only calls its two closures.
struct FeedbackNoticeCard: View {
    let notice: FeedbackNotice
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.smoothGrape)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.title)
                            .font(.lhfSans(14, weight: .semibold))
                            .foregroundStyle(Color.v2Ink)
                            .multilineTextAlignment(.leading)
                        if let subtitle = notice.subtitle {
                            Text(subtitle)
                                .font(.lhfSans(12))
                                .foregroundStyle(Color.v2DateText)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(for: notice))

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.v2DateText)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.v2Card)
                .shadow(color: Color.v2CardShadow.opacity(0.15), radius: 8, y: 3)
        )
        // 20 and 12, not the banner's 16 and 8: the card sits in the
        // dashboard's own column, between the header and the sync banner,
        // which both use 20 at the sides and 12 above.
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// Title, then subtitle when there is one.
    static func accessibilityLabel(for notice: FeedbackNotice) -> String {
        if let subtitle = notice.subtitle { return "\(notice.title). \(subtitle)" }
        return notice.title
    }
}

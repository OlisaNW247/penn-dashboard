import SwiftUI
import LowHangingFruitKit

/// The soft nudge shown when `UpdateGateStore.verdict` is
/// `.updateAvailable`: a newer build exists, but the one on the student's
/// phone still works fine, so this is advisory and dismissible rather than
/// blocking — the undismissable case is `UpdateRequiredView`.
///
/// **Why this banner's dismissal is persisted per-version, unlike
/// `ContentView`'s "you're not fully connected" notice.** Read that notice's
/// own doc comment at `ContentView.swift:22-29` first: it deliberately does
/// *not* persist, because its rationale is "half your work is silently
/// missing" — a correctness problem the student needs to notice and act on,
/// so it comes back every launch until the underlying gap is fixed. This
/// banner is not that. An available-but-optional update is not a
/// correctness problem — the app keeps working exactly as before — so
/// re-nagging on every single launch would just teach the student to ignore
/// LHF's notices in general, including the ones (the connection notice, the
/// hard update wall) that actually matter. Persisting the dismissal keyed by
/// `latest`'s version string is also why an update the student *hasn't*
/// dismissed still gets surfaced: the key is per-version, so dismissing the
/// nudge for 2.1.0 says nothing about 2.2.0 — a maintainer shipping another
/// release re-arms the nudge for free, with no "un-dismiss" mechanism
/// needed. The persistence itself lives in `UpdateGateStore` (`UserDefaults
/// .lhf`, never `.standard`); this view only calls `dismiss()`.
struct UpdateAvailableBanner: View {
    let latest: AppVersion
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.v2SpineBlue)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("an update is available")
                    .font(.lhfSans(14, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                Text("version \(latest.description) is out. Update whenever you'd like from the App Store.")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

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
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

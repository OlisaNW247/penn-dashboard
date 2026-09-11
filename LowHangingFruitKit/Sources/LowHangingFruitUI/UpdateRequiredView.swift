import SwiftUI
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The full-screen, undismissable wall shown when `UpdateGateStore.verdict`
/// is `.updateRequired`. There is no dismiss gesture, no close button, and no
/// swipe or tap-outside that gets past it — `RootCore` stacks it above
/// `mainContent` (onboarding included) for exactly that reason: a build
/// below the enforced floor is meant to do nothing at all until the student
/// updates.
///
/// Built from the app's own visual language (`RedesignTokens.swift`'s `v2*`
/// dynamic colors, its `lhfSans`/`lhfSerif` fonts, and `SmoothAppMark`, the
/// app's icon) rather than a system `Alert` or `ContentUnavailableView`, so
/// it reads as the app itself telling the student something, not as an
/// OS-level interruption.
struct UpdateRequiredView: View {
    let minimum: AppVersion
    let message: String?
    let appStoreURL: URL?

    /// Shown when the hosted policy didn't set a `message` — which is
    /// itself expected to be rare (a maintainer publishing a `minimumVersion`
    /// would normally explain why), but `message` is `Optional` precisely
    /// because a policy can omit it, and the wall still has to say
    /// *something* rather than show blank space above the button.
    private static let fallbackMessage =
        "This version of Smooth is too old to keep working with Canvas. Update to keep your dashboard accurate."

    var body: some View {
        ZStack {
            Color.v2Bg.ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer(minLength: 0)

                // `SmoothAppMark` applies its own `.frame(width:height:)`
                // from `size` — see that file's doc comment for why it was
                // deliberately built that way, unlike the app's older
                // `GeometryReader`-expands-to-fill mark, whose `size:`
                // argument didn't actually constrain it and made this exact
                // wall render as a giant logo with the copy squeezed
                // underneath the first time this screen was built. No extra
                // `.frame` needed here as a result.
                SmoothAppMark(size: 64)

                Text("time for an update")
                    .font(.lhfSerif(32))
                    .foregroundStyle(Color.v2Ink)
                    .multilineTextAlignment(.center)

                // The remote manifest is exactly that — remote. Rendering it
                // with `Text(_:)` (a string literal or interpolated string)
                // would parse the content as Markdown, which turns something
                // as ordinary as an underscore or asterisk in a maintainer's
                // message into unintended styling. `Text(verbatim:)` is the
                // one initializer that unambiguously does not interpret its
                // input, which is what a string arriving over the network
                // and landing on an undismissable screen needs.
                Text(verbatim: message ?? Self.fallbackMessage)
                    .font(.lhfSans(16))
                    .foregroundStyle(Color.v2DateText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36)

                // A wall with a button that does nothing is worse than a
                // wall with no button at all — a dead tap reads as the app
                // being broken, not as "there's nothing more to do here."
                // `appStoreURL` is `nil` whenever the hosted policy either
                // omitted it or failed `UpdatePolicy`'s host allowlist (see
                // that type's doc comment), so this button simply doesn't
                // exist in that case rather than being shown disabled or,
                // worse, tappable and inert.
                if let appStoreURL {
                    Button {
                        openAppStore(appStoreURL)
                    } label: {
                        Text("update now")
                            .font(.lhfSans(16, weight: .semibold))
                            .foregroundStyle(Color.v2ToggleActiveTx)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.v2Ink)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 36)
                    .padding(.top, 4)
                }

                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 40)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// Same `#if canImport(UIKit)` / `#elseif canImport(AppKit)` split as
    /// `SupportContact.openReportMail` — the only cross-platform way to open
    /// an external URL from a library target that ships on both iOS and
    /// macOS.
    private func openAppStore(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

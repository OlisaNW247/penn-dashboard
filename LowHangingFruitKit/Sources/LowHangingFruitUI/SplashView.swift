import SwiftUI
import AVFoundation
import Combine
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// First-launch splash: plays the bundled intro clip once on a field that
/// matches the clip's own background, so the square clip sits seamlessly, then
/// hands off to the app. A timeout guards against a clip that never loads.
struct SplashView: View {
    /// Resolved by the caller (`RootView`) from `AppState.appearanceMode`
    /// directly — NOT from `@Environment(\.colorScheme)`. The splash is the
    /// very first view on screen, and on first launch `.preferredColorScheme`
    /// (applied at the ZStack root, from the same `AppState`) doesn't finish
    /// propagating into the environment until after this view's first render
    /// pass. Reading straight from the already-loaded `AppState` instead is
    /// synchronous and available before the first render, so there's no race.
    /// See `SplashPlayer.Coordinator.start` for why runtime changes don't
    /// need to be handled here.
    let isDarkMode: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Light mode plays the original clip, whose decoded background measures
    /// ~#FDF8EF (±2 of compression noise); the previous #FCF5EC was a few
    /// levels darker, which showed the square clip as a faint box on screen.
    /// Dark mode plays a separate pre-rendered asset (`splash_dark.mp4`,
    /// generated offline by flood-filling the clip's cream background to
    /// `v2Bg` while leaving the artwork's own colors untouched — see
    /// `SplashPlayer`), so this field matches `v2Bg` too and there's no
    /// visible seam around the clip.
    private var background: Color {
        isDarkMode ? .v2Bg : Color(hex: 0xFDF8EF)
    }

    /// The clip's background isn't perfectly uniform (compression noise, a
    /// slight vignette), so no constant can match it everywhere. Fading the
    /// outer ~5% of the clip into the field hides any residual step — and
    /// softens the hard crop line when artwork crosses the clip's edge.
    private static let featherStops: [Gradient.Stop] = [
        .init(color: .clear, location: 0),
        .init(color: .black, location: 0.05),
        .init(color: .black, location: 0.95),
        .init(color: .clear, location: 1),
    ]

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if reduceMotion {
                // Respect Reduce Motion: no autoplaying clip — show the wordmark.
                Text("LHF")
                    .font(.lhfSerif(56))
                    .foregroundStyle(Color.v2Ink)
            } else {
                SplashPlayer(onFinished: onFinished, isDarkMode: isDarkMode)
                    .aspectRatio(1, contentMode: .fit)   // the clip is 1:1
                    // Two axis masks multiply into a four-edge feather.
                    .mask(LinearGradient(stops: Self.featherStops, startPoint: .leading, endPoint: .trailing))
                    .mask(LinearGradient(stops: Self.featherStops, startPoint: .top, endPoint: .bottom))
                    .padding(.horizontal, 24)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Low Hanging Fruit")
        .task {
            // Reduce Motion shows a brief static beat; otherwise a safety net so
            // a clip that never loads or ends can't strand the user. The cancel
            // check avoids a redundant fire once the video already dismissed us.
            let seconds: UInt64 = reduceMotion ? 1 : 6
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if !Task.isCancelled { onFinished() }
        }
    }
}

// MARK: - AVPlayer host (no transport controls)

private struct SplashPlayer {
    let onFinished: () -> Void
    /// Selects which bundled clip to play. Dark mode plays a distinct
    /// pre-rendered asset (`splash_dark.mp4`) rather than recoloring the
    /// light clip at runtime — an earlier CIFalseColor video composition
    /// attempt didn't reliably apply on-device and, worse, desaturated the
    /// artwork itself (killing the persimmon's orange). The dark asset is
    /// generated offline by flood-filling only the clip's cream *background*
    /// to `v2Bg`, leaving the hand/fruit/leaves at their original colors.
    /// When `false` playback is byte-identical to the original implementation.
    /// Resolved once by `SplashView` from `AppState.appearanceMode` (not the
    /// SwiftUI environment's `colorScheme`) — see that file's `isDarkMode` doc
    /// for why. `Coordinator.start` runs once, at `makeUIView`/`makeNSView`
    /// time, and the appearance setting isn't reachable from Settings while
    /// the splash is covering the screen, so there's no in-flight value for
    /// this run to go stale against — a runtime swap-the-item path would be
    /// dead code.
    var isDarkMode: Bool = false

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    @MainActor
    final class Coordinator {
        private static let logger = Logger(subsystem: "com.lhf.lowhangingfruit", category: "SplashPlayer")

        private let onFinished: () -> Void
        private var didFinish = false
        private var endObservation: AnyCancellable?
        let player = AVPlayer()

        init(onFinished: @escaping () -> Void) { self.onFinished = onFinished }

        func start(isDarkMode: Bool) {
            // If the clip is somehow missing (a packaging regression), do nothing
            // here — calling back synchronously would mutate parent state mid
            // view-update. SplashView's safety-net timeout dismisses instead.
            let name = isDarkMode ? "splash_dark" : "splash"
            let url = Bundle.module.url(forResource: name, withExtension: "mp4")
            Self.logger.log("splash asset selection: isDarkMode=\(isDarkMode, privacy: .public) resource=\(name, privacy: .public) bundleURLFound=\(url != nil, privacy: .public) url=\(url?.absoluteString ?? "nil", privacy: .public)")
            guard let url else { return }
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .pause
            player.isMuted = true
            // Combine (non-@Sendable sink) sidesteps the @Sendable-capture warning
            // that the block-based observer trips under Swift 6 strict concurrency;
            // `receive(on:)` guarantees the callback lands on the main thread, and
            // the cancellable tears the observation down with the coordinator.
            endObservation = NotificationCenter.default
                .publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.finishOnce() }
            player.play()
        }

        private func finishOnce() {
            guard !didFinish else { return }
            didFinish = true
            onFinished()
        }
    }
}

#if canImport(UIKit)
extension SplashPlayer: UIViewRepresentable {
    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = context.coordinator.player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        context.coordinator.start(isDarkMode: isDarkMode)
        return view
    }
    func updateUIView(_ uiView: PlayerHostView, context: Context) {}
}

/// A view whose backing layer *is* an AVPlayerLayer, so the clip renders with no
/// transport controls (unlike AVKit's `VideoPlayer`).
private final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#elseif canImport(AppKit)
extension SplashPlayer: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = context.coordinator.player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.start(isDarkMode: isDarkMode)
        return view
    }
    func updateNSView(_ nsView: PlayerHostView, context: Context) {}
}

private final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#endif

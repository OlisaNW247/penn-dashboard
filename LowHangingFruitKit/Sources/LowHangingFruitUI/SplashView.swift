import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Combine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// First-launch splash: plays the bundled intro clip once on a cream field that
/// matches the video's own background, so the square clip sits seamlessly, then
/// hands off to the app. A timeout guards against a clip that never loads.
struct SplashView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The clip's actual decoded background, measured from its edge pixels
    /// (~#FDF8EF ±2 of compression noise). The previous #FCF5EC was a few
    /// levels darker, which showed the square clip as a faint box on screen.
    /// There's no dark-mode video asset, so in Light mode this (and playback)
    /// stays byte-identical to before; in Dark mode the field instead matches
    /// `v2Bg` so letterboxing around the recolored clip doesn't flash white.
    private var background: Color {
        colorScheme == .dark ? .v2Bg : Color(hex: 0xFDF8EF)
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
                SplashPlayer(onFinished: onFinished, isDarkMode: colorScheme == .dark)
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
    /// No dark-mode video asset exists, so Dark mode recolors the same clip
    /// in code via a Core Image video composition (see `Coordinator.start`).
    /// When `false` this whole path is skipped, so Light-mode playback stays
    /// byte-identical to the original implementation.
    var isDarkMode: Bool = false

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    @MainActor
    final class Coordinator {
        private let onFinished: () -> Void
        private var didFinish = false
        private var endObservation: AnyCancellable?
        let player = AVPlayer()

        init(onFinished: @escaping () -> Void) { self.onFinished = onFinished }

        func start(isDarkMode: Bool) {
            // If the clip is somehow missing (a packaging regression), do nothing
            // here — calling back synchronously would mutate parent state mid
            // view-update. SplashView's safety-net timeout dismisses instead.
            guard let url = Bundle.module.url(forResource: "splash", withExtension: "mp4") else { return }
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            if isDarkMode {
                item.videoComposition = Self.darkVideoComposition(asset: asset)
            }
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

        /// Recolors the light-mode clip to match the dark palette instead of
        /// showing it as-is (which would flash a bright cream square) or
        /// naively inverting it (which flips hue on any colored content).
        /// `CIFalseColor` remaps luminance onto the app's own two dark-mode
        /// tokens — `v2Ink` (light, for what was dark ink) at the shadow end
        /// and `v2Bg` (near-black, for what was the cream field) at the
        /// highlight end — so the treatment reads as a deliberate dark variant
        /// of the same mark, not a photo-negative effect.
        private static func darkVideoComposition(asset: AVAsset) -> AVVideoComposition {
            let inkColor = CIColor(red: 0xEF / 255, green: 0xEC / 255, blue: 0xE6 / 255)   // v2Ink (dark mode)
            let bgColor  = CIColor(red: 0x1C / 255, green: 0x1A / 255, blue: 0x17 / 255)   // v2Bg  (dark mode)
            return AVMutableVideoComposition(asset: asset) { request in
                let source = request.sourceImage.clampedToExtent()
                let desaturated = source.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.0,
                ])
                let falseColor = desaturated.applyingFilter("CIFalseColor", parameters: [
                    "inputColor0": inkColor,
                    "inputColor1": bgColor,
                ])
                request.finish(with: falseColor.cropped(to: request.sourceImage.extent), context: nil)
            }
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

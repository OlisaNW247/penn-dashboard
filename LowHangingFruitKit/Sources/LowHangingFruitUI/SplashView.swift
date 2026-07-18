import SwiftUI
import AVFoundation
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

    /// Matches the video's background (#FCF5EC) so there are no visible edges.
    static let background = Color(hex: 0xFCF5EC)

    var body: some View {
        ZStack {
            Self.background.ignoresSafeArea()

            if reduceMotion {
                // Respect Reduce Motion: no autoplaying clip — show the wordmark.
                Text("LHF")
                    .font(.lhfSerif(56))
                    .foregroundStyle(Color.v2Ink)
            } else {
                SplashPlayer(onFinished: onFinished)
                    .aspectRatio(1, contentMode: .fit)   // the clip is 1:1
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

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    final class Coordinator {
        private let onFinished: () -> Void
        private var didFinish = false
        private var endObservation: AnyCancellable?
        let player = AVPlayer()

        init(onFinished: @escaping () -> Void) { self.onFinished = onFinished }

        func start() {
            // If the clip is somehow missing (a packaging regression), do nothing
            // here — calling back synchronously would mutate parent state mid
            // view-update. SplashView's safety-net timeout dismisses instead.
            guard let url = Bundle.module.url(forResource: "splash", withExtension: "mp4") else { return }
            let item = AVPlayerItem(url: url)
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
        context.coordinator.start()
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
        context.coordinator.start()
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

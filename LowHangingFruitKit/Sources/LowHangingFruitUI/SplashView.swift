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
            // Scaled by the same factor as playback so the net stays a safety
            // net — a fixed 6s would now outlast the sped-up clip by seconds.
            let seconds = reduceMotion ? 1 : 6 / Double(SplashPlayer.playbackRate)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { onFinished() }
        }
    }
}

// MARK: - AVPlayer host (no transport controls)

private struct SplashPlayer {
    /// Playback speed for the intro clip. 1.4 = 40% faster than recorded; the
    /// asset itself is untouched, so this is reversible by changing one number.
    /// `SplashView`'s safety-net timeout divides by this, keeping the two in step.
    static let playbackRate: Float = 1.4

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
            // Before the player is touched at all: make sure that starting it
            // cannot evict whatever the user is already listening to. See the
            // function's note — the clip is silent, and the interruption comes
            // from session activation rather than from any sound.
            Self.configureAudioSessionForSilentPlayback()
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .pause
            // Belt and braces. Both bundled clips are video-only, so this is a
            // no-op today; it stays because it costs nothing and is the right
            // default if an asset with an audio track is ever swapped in.
            player.isMuted = true
            // Combine (non-@Sendable sink) sidesteps the @Sendable-capture warning
            // that the block-based observer trips under Swift 6 strict concurrency;
            // `receive(on:)` guarantees the callback lands on the main thread, and
            // the cancellable tears the observation down with the coordinator.
            endObservation = NotificationCenter.default
                .publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.finishOnce() }
            // Setting a positive rate starts playback, so this replaces play()
            // rather than following it (play() would reset the rate to 1).
            player.rate = SplashPlayer.playbackRate
        }

        /// Makes the intro clip a guest in whatever audio is already playing,
        /// instead of the owner of the device's audio.
        ///
        /// **The clip has no sound, and never did.** This lands as a bug report
        /// that reads "remove the sound from the intro video — it stops my
        /// Spotify," and the obvious fix is the wrong one. Both `splash.mp4`
        /// and `splash_dark.mp4` are video-only: `ffprobe` reports exactly one
        /// h264 stream and no audio track on each. `start(isDarkMode:)` also
        /// sets `player.isMuted = true` on top of that. There is no sound to
        /// remove, and muting harder — or re-encoding the assets to strip an
        /// audio track that isn't there — accomplishes nothing. If the symptom
        /// ever comes back, it is not the volume.
        ///
        /// What actually stops Spotify is the **session activation**, not
        /// anything audible. An app that never configures `AVAudioSession` gets
        /// the system default category, `.soloAmbient`, whose entire semantic is
        /// "while I am active, everyone else is silenced." `AVPlayer` implicitly
        /// activates the process's shared session the instant playback begins,
        /// so merely starting a muted, soundless clip is enough to evict another
        /// app's audio. `.ambient` is the opposite promise — this app's audio is
        /// incidental and never worth interrupting anyone over — and
        /// `.mixWithOthers` says so explicitly rather than leaning on
        /// `.ambient`'s implicit mixing behaviour.
        ///
        /// **Why here, and not at launch or in `init`.** This is the only
        /// `AVPlayer` in the app and `start` is the only place it ever plays,
        /// so this is the narrowest point that is still guaranteed to precede
        /// activation. Reaching this line also means the clip was found and is
        /// genuinely about to roll; configuring process-global audio state from
        /// `init`, or from app launch, would reconfigure the process for a
        /// splash that may never play (Reduce Motion skips the player entirely,
        /// and a missing asset returns before this point). The category is
        /// sticky process state, so one call per launch is enough — and because
        /// it is idempotent, a second splash presentation re-setting it costs a
        /// syscall and nothing else.
        ///
        /// **Nothing is torn down when the splash ends, deliberately.** There is
        /// no matching `setActive(false)` and there should not be. `.ambient`
        /// interrupted nobody, so there is no one to hand the session back to,
        /// and deactivating with `.notifyOthersOnDeactivation` would broadcast a
        /// spurious "you may resume" to apps this app never paused. An idle
        /// `.ambient` session costs other apps exactly nothing.
        ///
        /// **A throw is logged and swallowed, on purpose.** The worst case for a
        /// failed `setCategory` is the behaviour already shipping today — the
        /// user's music pauses — whereas letting it propagate would let a
        /// decorative animation take the app's launch down with it. Degrading to
        /// the old bug is strictly better than degrading to a black screen.
        private static func configureAudioSessionForSilentPlayback() {
            // `AVAudioSession` is an iOS-family type. It does not exist on
            // macOS, where AppKit apps mix with other audio by default and need
            // no equivalent call — so this compiles out entirely rather than
            // being stubbed. The guard is written against the OS rather than the
            // file's usual `canImport(UIKit)` split because availability here is
            // a property of the platform's audio stack, not of its UI framework
            // (Mac Catalyst is `os(iOS)` and does have `AVAudioSession`).
            #if os(iOS) || os(tvOS) || os(visionOS)
            do {
                try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            } catch {
                Self.logger.error("audio session setCategory(.ambient, .mixWithOthers) failed: \(error.localizedDescription, privacy: .public) — the intro clip may interrupt other apps' audio, but playback continues")
            }
            #endif
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

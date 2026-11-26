import Foundation
#if canImport(AVFoundation) && canImport(ImageIO)
import AVFoundation
import CoreGraphics
#endif

/// Turns a screen recording of a campus feed into a handful of still
/// pictures, so the founders can see what posts look like at the ambassador's
/// school without the phone ever uploading the video.
///
/// Stills, not the clip, on purpose: a two-minute recording is tens of
/// megabytes and would carry whatever else scrolled past (a notification
/// banner, a name), where a still is a single frame the student can be told to
/// check. Each frame goes through `PosterIdeaImage`, so it is re-encoded from
/// its pixels with no metadata.
public enum FeedRecordingFrames {
    /// Where to take stills from a recording `duration` seconds long: evenly
    /// spaced, strictly inside the clip (a frame at exactly 0 is usually a
    /// black or half-drawn first frame, and one at the very end can be past the
    /// last decodable frame), at most `maxFrames`, and never closer than
    /// `minSpacing` so a short clip is not sampled into near-duplicates.
    /// At least one time for any positive, finite duration, however short.
    ///
    /// The spacing between neighbours is `duration / (n + 1)`, so the count
    /// that keeps it at `minSpacing` or more is `duration / minSpacing - 1`.
    /// The wrong fix is `duration / minSpacing` frames: the end gaps (first
    /// frame to the start, last to the end) would then be the only ones that
    /// obey the rule, and the inner ones would be short by one slot.
    public static func sampleTimes(duration: Double, maxFrames: Int = 16, minSpacing: Double = 1.5) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let cap = max(1, maxFrames)
        var count = cap
        if minSpacing > 0 {
            let fit = Int((duration / minSpacing).rounded(.down)) - 1
            count = min(cap, max(1, fit))
        }
        return (1...count).map { duration * Double($0) / Double(count + 1) }
    }

    /// A fresh random id for one recording, twelve characters of `a-z0-9`:
    /// what the server groups a recording's stills by.
    public static func newBatchID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in alphabet.randomElement() ?? "a" })
    }

#if canImport(AVFoundation) && canImport(ImageIO)
    /// JPEG stills from the video at `url`, in order. A frame that cannot be
    /// read is skipped, and an unreadable file gives an empty array; the caller
    /// says so in words.
    ///
    /// `nonisolated` and self-contained on purpose: the generator is not
    /// `Sendable`, so it is created and used inside this one function and only
    /// `[Data]` leaves it, which keeps Swift 6 from seeing a value cross an
    /// isolation boundary.
    public nonisolated static func frames(from url: URL, maxFrames: Int = 16, maxDimension: Int = 1200,
                                          maxBytes: Int = 200_000) async -> [Data] {
        let asset = AVURLAsset(url: url)
        guard let loaded = try? await asset.load(.duration) else { return [] }
        let seconds = CMTimeGetSeconds(loaded)
        let times = sampleTimes(duration: seconds, maxFrames: maxFrames)
        guard !times.isEmpty else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        // Any frame near the asked time will do; exact seeks are slow on a
        // long recording and nobody needs the stills frame-accurate.
        let slack = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        var stills: [Data] = []
        for time in times {
            let moment = CMTime(seconds: time, preferredTimescale: 600)
            guard let result = try? await generator.image(at: moment) else { continue }
            if let jpeg = PosterIdeaImage.prepared(cgImage: result.image, maxDimension: maxDimension, maxBytes: maxBytes) {
                stills.append(jpeg)
            }
        }
        return stills
    }
#endif
}

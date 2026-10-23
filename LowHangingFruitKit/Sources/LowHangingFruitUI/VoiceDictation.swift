import Foundation

/// What the mic button in ask's composer should do right now. Pure, so the
/// rules below are tested on the Mac; the part that touches the microphone
/// is `VoiceDictationController`, which only exists on iOS.
enum VoiceDictationAvailability: Equatable {
    /// No button at all. The device or locale cannot recognise speech
    /// on-device, and the privacy promise is that audio never leaves the
    /// phone, so there is no server fallback to offer instead.
    case hidden
    /// Both permissions are granted and on-device recognition works.
    case ready
    /// At least one permission has not been asked yet; the first tap asks.
    case needsPermission
    /// A permission was refused. The button stays so the student can find the
    /// way back: a tap opens the app's page in Settings.
    case denied
}

/// The decisions behind voice dictation in ask, kept free of Speech and
/// AVFoundation so they compile on every platform `swift test` builds for.
///
/// **Why on-device only.** Apple's recogniser can send audio to its servers
/// unless the request says `requiresOnDeviceRecognition`. `docs/PRIVACY.md`
/// promises what a student says never leaves the phone, so a device that
/// cannot recognise locally gets no mic button, not a quiet cloud fallback.
/// The wrong fix is offering the button everywhere and leaving the flag off
/// "for devices that need it".
///
/// **Why nothing auto-sends.** Recognition mishears. Words that land in the
/// field are a draft the student reads and sends; sending on silence or on
/// the final result would put a question to the model that the student
/// never actually asked, and spend the quota ask shares.
enum VoiceDictationRules {

    /// A safety stop so a tap in a pocket cannot leave the microphone open.
    static let maximumListen: TimeInterval = 60

    /// `nil` for a permission means "not asked yet". Hidden wins over
    /// everything, because a student who cannot dictate should not be sent to
    /// Settings or asked for permissions that would buy them nothing.
    static func availability(
        recognizerAvailable: Bool,
        supportsOnDevice: Bool,
        speechAuthorized: Bool?,
        micAuthorized: Bool?
    ) -> VoiceDictationAvailability {
        guard recognizerAvailable, supportsOnDevice else { return .hidden }
        if speechAuthorized == false || micAuthorized == false { return .denied }
        if speechAuthorized == nil || micAuthorized == nil { return .needsPermission }
        return .ready
    }

    /// The text the field shows while listening: what was typed when the
    /// listening began (trailing whitespace dropped, so a newline does not
    /// become a gap), one space if there was anything, then the transcript.
    /// The transcript is the recogniser's whole result so far, not a delta, so
    /// this is always computed from the draft as it was at the start and never
    /// from the field's current text, which would repeat the words each time
    /// a partial result arrives.
    static func merged(draft: String, transcript: String) -> String {
        guard !transcript.isEmpty else { return draft }
        var head = draft
        while let last = head.last, last.isWhitespace { head.removeLast() }
        return head.isEmpty ? transcript : head + " " + transcript
    }
}

// Everything here is iOS-only. The Mac composer is unchanged, and `swift test`
// compiles the macOS slice, where Speech's on-device path and the audio
// session do not apply. The decisions live in `VoiceDictation.swift`.
#if os(iOS)
import AVFoundation
import Speech
import UIKit

/// Live dictation for ask's composer: the words stream into `transcript`
/// while `isListening`, and the view merges them into the draft. It never
/// sends anything (see `VoiceDictationRules`).
///
/// **On-device is the privacy guarantee.** `requiresOnDeviceRecognition = true`
/// below is what keeps audio on the phone; without it Apple's recogniser may
/// use its servers. Never omit it, and never add a fallback when it is
/// unsupported: `availability` is `.hidden` in that case and `start()` is
/// never reached.
///
/// **Concurrency.** The audio tap and the recognition result handler are
/// called on other queues. A closure written inside a main-actor method
/// inherits that isolation and then traps at run time when called off the
/// main queue (the same trap as the background-refresh handler in CLAUDE.md),
/// so both closures are built in `nonisolated` static functions and hand only
/// plain values back through `Task { @MainActor in }`.
///
/// **The audio session.** The app never configures `AVAudioSession` itself,
/// and `.record` interrupts other audio on its own; ducking is not an option
/// for that category (`setCategory` throws if it is asked for, and the mic
/// then never starts). So `start()` remembers the category, mode and options
/// it found and `stop()` puts them back after telling other apps they can
/// resume, rather than leaving the phone in a record category until the app
/// is killed.
///
/// **Who stops it.** The mic must not stay open behind the student's back, so
/// besides the tap, the send, the 60 s ceiling and a final result, the view
/// stops it when it disappears, when the scene leaves the foreground and when
/// the field is focused for typing, and this class stops it when the system
/// interrupts audio (a call, Siri). There is no `deinit` stop: a main-actor
/// class cannot safely call its own main-actor methods from `deinit` in
/// Swift 6, so the view's `onDisappear` is the backstop.
@MainActor
final class VoiceDictationController: ObservableObject {

    @Published private(set) var availability: VoiceDictationAvailability
    @Published private(set) var isListening = false
    /// The recogniser's whole result so far, partial or final.
    @Published private(set) var transcript = ""

    private let recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Task<Void, Never>?
    private var previousSession: (
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    )?
    /// Bumped at every start and stop, so a late callback from a task that
    /// was already cancelled cannot write into the next listening.
    private var generation = 0
    private var isRequestingPermission = false
    private var interruptionObserver: NSObjectProtocol?

    private enum StartError: Error { case noInput }

    init() {
        let made = SFSpeechRecognizer(locale: .current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
        recognizer = made
        availability = Self.currentAvailability(made)
    }

    private static func currentAvailability(_ recognizer: SFSpeechRecognizer?) -> VoiceDictationAvailability {
        let speech: Bool?
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = true
        case .notDetermined: speech = nil
        default: speech = false
        }
        let mic: Bool?
        switch AVAudioApplication.shared.recordPermission {
        case .granted: mic = true
        case .undetermined: mic = nil
        default: mic = false
        }
        return VoiceDictationRules.availability(
            recognizerAvailable: recognizer?.isAvailable ?? false,
            supportsOnDevice: recognizer?.supportsOnDeviceRecognition ?? false,
            speechAuthorized: speech,
            micAuthorized: mic
        )
    }

    // MARK: Tap

    func toggle() {
        // The student may have changed a permission in Settings since the
        // last look; a stale "denied" would reopen Settings for nothing.
        availability = Self.currentAvailability(recognizer)
        if isListening {
            stop()
            return
        }
        switch availability {
        case .hidden:
            return
        case .denied:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .ready:
            start()
        case .needsPermission:
            guard !isRequestingPermission else { return }
            isRequestingPermission = true
            Task { [self] in
                // One prompt at a time: a refusal of speech recognition ends
                // it, so the student is not also asked for the microphone for
                // a feature they just said no to.
                let speech = await Self.requestSpeech()
                guard speech else {
                    isRequestingPermission = false
                    availability = Self.currentAvailability(recognizer)
                    return
                }
                let mic = await AVAudioApplication.requestRecordPermission()
                isRequestingPermission = false
                availability = Self.currentAvailability(recognizer)
                // Only start on the tap that granted both; a refusal leaves
                // the button saying "denied" without any message (copy rule).
                if mic && availability == .ready { start() }
            }
        }
    }

    nonisolated private static func requestSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: Listening

    private func start() {
        guard !isListening, let recognizer else { return }
        transcript = ""
        generation += 1
        let mine = generation
        do {
            let session = AVAudioSession.sharedInstance()
            previousSession = (session.category, session.mode, session.categoryOptions)
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            interruptionObserver = Self.observeInterruptions(owner: self)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            self.request = request

            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // A zero sample rate is a microphone that is not there (another
            // app holds it, or a call is up); installing a tap would throw.
            guard format.sampleRate > 0 else { throw StartError.noInput }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(request))
            engine.prepare()
            try engine.start()

            task = recognizer.recognitionTask(
                with: request,
                resultHandler: Self.resultHandler(owner: self, generation: mine)
            )
            isListening = true

            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(VoiceDictationRules.maximumListen * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            // No alert and no text: the mic simply does not start.
            stop()
        }
    }

    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        isListening = false

        if let previous = previousSession {
            previousSession = nil
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(previous.category, mode: previous.mode, options: previous.options)
        }
    }

    private func received(text: String?, finished: Bool, generation seen: Int) {
        guard seen == generation, isListening else { return }
        if let text { transcript = text }
        if finished { stop() }
    }

    // MARK: Off-main callbacks

    nonisolated private static func tapBlock(
        _ request: SFSpeechAudioBufferRecognitionRequest
    ) -> AVAudioNodeTapBlock {
        // The request is not Sendable and the tap runs on the audio thread.
        // Appending from that thread is exactly how Apple's own sample uses
        // it; the annotation only tells Swift 6 not to reject the capture.
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    /// Built off the main actor for the same reason as the two closures below.
    /// Only the start of an interruption matters; the student taps again to
    /// resume, because a mic that reopens by itself is the thing to avoid.
    nonisolated private static func observeInterruptions(
        owner: VoiceDictationController
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak owner] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            guard began, let owner else { return }
            Task { @MainActor in owner.stop() }
        }
    }

    nonisolated private static func resultHandler(
        owner: VoiceDictationController,
        generation: Int
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let finished = (result?.isFinal ?? false) || error != nil
            guard let owner else { return }
            Task { @MainActor in
                owner.received(text: text, finished: finished, generation: generation)
            }
        }
    }
}
#endif

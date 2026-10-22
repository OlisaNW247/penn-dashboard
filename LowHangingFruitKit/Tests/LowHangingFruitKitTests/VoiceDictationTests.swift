import Foundation
import Testing
@testable import LowHangingFruitUI

/// Voice dictation in ask. The pure rules are tested here; the controller
/// itself is iOS-only and `swift test` compiles the macOS slice, so what can
/// be pinned about it is its source: that on-device recognition is demanded,
/// that the audio session is handed back, and that nothing the transcript does
/// can send a question. That the mic really listens, the permission prompts
/// appear and the words stream in are things only a phone proves.
@Suite("Voice dictation rules")
struct VoiceDictationRulesTests {

    private func availability(
        recognizer: Bool = true, onDevice: Bool = true, speech: Bool? = true, mic: Bool? = true
    ) -> VoiceDictationAvailability {
        VoiceDictationRules.availability(
            recognizerAvailable: recognizer, supportsOnDevice: onDevice,
            speechAuthorized: speech, micAuthorized: mic)
    }

    @Test("Ready only when both permissions are granted and on-device recognition works")
    func readyNeedsEverything() {
        #expect(availability() == .ready)
    }

    @Test("No recogniser or no on-device support hides the button, whatever the permissions say")
    func hiddenBeatsEverything() {
        for speech in [true, false, nil] as [Bool?] {
            for mic in [true, false, nil] as [Bool?] {
                #expect(availability(recognizer: false, speech: speech, mic: mic) == .hidden)
                #expect(availability(onDevice: false, speech: speech, mic: mic) == .hidden)
            }
        }
    }

    @Test("A refused permission is denied even when the other has not been asked")
    func deniedBeatsNeedsPermission() {
        #expect(availability(speech: false, mic: nil) == .denied)
        #expect(availability(speech: nil, mic: false) == .denied)
        #expect(availability(speech: false, mic: true) == .denied)
        #expect(availability(speech: true, mic: false) == .denied)
        #expect(availability(speech: false, mic: false) == .denied)
    }

    @Test("Either permission not yet asked needs permission")
    func needsPermission() {
        #expect(availability(speech: nil, mic: nil) == .needsPermission)
        #expect(availability(speech: nil, mic: true) == .needsPermission)
        #expect(availability(speech: true, mic: nil) == .needsPermission)
    }

    @Test("Listening stops by itself after a minute")
    func maximumListen() {
        #expect(VoiceDictationRules.maximumListen == 60)
    }

    @Test("An empty draft shows the transcript alone")
    func mergedEmptyDraft() {
        #expect(VoiceDictationRules.merged(draft: "", transcript: "when is the final") == "when is the final")
    }

    @Test("A draft's trailing space or newline becomes one space, not a gap")
    func mergedTrailingWhitespace() {
        #expect(VoiceDictationRules.merged(draft: "also, ", transcript: "when is it") == "also, when is it")
        #expect(VoiceDictationRules.merged(draft: "also,\n", transcript: "when is it") == "also, when is it")
        #expect(VoiceDictationRules.merged(draft: "also,", transcript: "when is it") == "also, when is it")
    }

    @Test("An empty transcript leaves the draft exactly as it was")
    func mergedEmptyTranscript() {
        #expect(VoiceDictationRules.merged(draft: "keep this \n", transcript: "") == "keep this \n")
        #expect(VoiceDictationRules.merged(draft: "", transcript: "") == "")
    }

    @Test("A whitespace-only draft contributes nothing")
    func mergedBlankDraft() {
        #expect(VoiceDictationRules.merged(draft: "  \n", transcript: "hello") == "hello")
    }

    @Test("Each partial result is merged onto the same starting draft, so words are never repeated")
    func partialsDoNotAccumulate() {
        let start = "also"
        #expect(VoiceDictationRules.merged(draft: start, transcript: "when") == "also when")
        #expect(VoiceDictationRules.merged(draft: start, transcript: "when is") == "also when is")
    }
}

@Suite("Voice dictation wiring")
struct VoiceDictationWiringTests {

    private static let mic = "Smooth listens only while the mic in ask is on, so you can say a question instead of typing it."
    private static let speech = "Your words are turned into text on this phone. Audio never leaves it."

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()    // .../LowHangingFruitKit
    }

    private func repoRoot() -> URL { packageRoot().deletingLastPathComponent() }

    /// A file that cannot be found is a failure, not a pass.
    private func read(_ url: URL) throws -> String {
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.path) is not there, so nothing could be checked")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func uiSource(_ filename: String) throws -> String {
        try read(packageRoot().appendingPathComponent("Sources/LowHangingFruitUI/\(filename)"))
    }

    @Test("Both usage strings are in App/Info.plist and in project.yml's app target, and identical")
    func usageDescriptionsInBothPlaces() throws {
        let plistData = try Data(contentsOf: repoRoot().appendingPathComponent("App/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let yml = try read(repoRoot().appendingPathComponent("project.yml"))
        let widgetTarget = try #require(yml.range(of: "\n  LHFWidgetExtension:"))

        for (key, expected) in [("NSMicrophoneUsageDescription", Self.mic),
                                ("NSSpeechRecognitionUsageDescription", Self.speech)] {
            let fromPlist = try #require(plist[key] as? String)
            #expect(fromPlist == expected)

            let found = try #require(yml.range(of: "\(key):"))
            #expect(found.lowerBound < widgetTarget.lowerBound, "\(key) belongs to the app target, not the widget's")
            let line = yml[found.upperBound...].prefix(while: { $0 != "\n" })
            let fromYML = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            #expect(fromYML == fromPlist)
        }
    }

    @Test("The controller is iOS-only from its first line of code and demands on-device recognition")
    func controllerIsIOSOnlyAndOnDevice() throws {
        let source = try uiSource("VoiceDictationController.swift")
        let firstCode = source.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.hasPrefix("//") }
        #expect(firstCode == "#if os(iOS)")
        // On the request itself: the doc comment repeats the bare phrase.
        #expect(source.contains("request.requiresOnDeviceRecognition = true"))
        #expect(!source.contains("requiresOnDeviceRecognition = false"))
    }

    @Test("The pure rules file imports no platform framework")
    func rulesFileIsPure() throws {
        let source = try uiSource("VoiceDictation.swift")
        for framework in ["Speech", "AVFoundation", "UIKit", "SwiftUI"] {
            #expect(!source.contains("import \(framework)"))
        }
    }

    @Test("Stopping hands the audio session back to other apps and restores the category")
    func sessionIsRestored() throws {
        let source = try uiSource("VoiceDictationController.swift")
        #expect(source.contains("notifyOthersOnDeactivation"))
        #expect(source.contains("setCategory(previous.category"))
    }

    @Test("ask merges the transcript into the draft and the handler never sends")
    func nothingAutoSends() throws {
        let source = try uiSource("AssistantView.swift")
        #expect(source.contains("VoiceDictationRules.merged"))
        let start = try #require(source.range(of: "onChange(of: dictation.transcript"))
        let handler = source[start.lowerBound...].prefix(while: { $0 != "\n" })
        #expect(handler.contains("VoiceDictationRules.merged"))
        #expect(!handler.contains("ask("))
        #expect(!handler.contains(".send("))
        // And the controller knows nothing about sending at all.
        let controller = try uiSource("VoiceDictationController.swift")
        // Word boundary: `recognitionTask(` contains "ask(".
        #expect(controller.range(of: #"\bask\("#, options: .regularExpression) == nil)
        #expect(!controller.contains(".send("))
    }

    @Test("The record category is set with no options: ducking is invalid for it and would stop the mic starting")
    func recordCategoryHasNoOptions() throws {
        let source = try uiSource("VoiceDictationController.swift")
        #expect(source.contains("setCategory(.record, mode: .measurement, options: [])"))
        #expect(!source.contains("duckOthers"))
    }

    @Test("Listening stops when the view goes away, the scene leaves the foreground, the field is focused, or audio is interrupted")
    func lifecycleStops() throws {
        let view = try uiSource("AssistantView.swift")
        #expect(view.contains(".onDisappear { dictation.stop() }"))
        #expect(view.contains("onChange(of: scenePhase)"))
        #expect(view.contains("onChange(of: composerFocused) { _, focused in if focused && dictation.isListening { dictation.stop() } }"))
        let controller = try uiSource("VoiceDictationController.swift")
        #expect(controller.contains("AVAudioSession.interruptionNotification"))
        #expect(controller.contains("removeObserver"))
    }

    @Test("The draft is captured when listening begins, not at the tap")
    func draftCapturedWhenListeningBegins() throws {
        let view = try uiSource("AssistantView.swift")
        #expect(view.contains("onChange(of: dictation.isListening) { _, on in if on { draftBeforeListening = draft } }"))
        // Exactly one assignment, and it is that one.
        #expect(view.components(separatedBy: "draftBeforeListening = ").count == 3, "the declaration and the one capture")
    }

    @Test("A refused speech prompt does not go on to ask for the microphone, and availability is refreshed on every tap")
    func permissionFlow() throws {
        let source = try uiSource("VoiceDictationController.swift")
        let speech = try #require(source.range(of: "let speech = await Self.requestSpeech()"))
        let guardSpeech = try #require(source.range(of: "guard speech else"))
        let mic = try #require(source.range(of: "await AVAudioApplication.requestRecordPermission()"))
        #expect(speech.lowerBound < guardSpeech.lowerBound && guardSpeech.lowerBound < mic.lowerBound)
        let toggle = try #require(source.range(of: "func toggle() {"))
        let refresh = try #require(source.range(of: "availability = Self.currentAvailability(recognizer)", range: toggle.upperBound..<source.endIndex))
        let firstSwitch = try #require(source.range(of: "switch availability", range: toggle.upperBound..<source.endIndex))
        #expect(refresh.lowerBound < firstSwitch.lowerBound)
    }

    @Test("The mic button has both accessibility labels and only shows when dictation is possible")
    func micButtonLabels() throws {
        let source = try uiSource("AssistantView.swift")
        #expect(source.contains("\"dictate\""))
        #expect(source.contains("\"stop listening\""))
        #expect(source.contains("dictation.availability != .hidden"))
    }

    @Test("Everything dictation adds to the composer sits inside #if os(iOS)")
    func composerIsGuarded() throws {
        let source = try uiSource("AssistantView.swift")
        for needle in ["VoiceDictationController()", "micButton", "dictation.stop()"] {
            let firstUse = try #require(source.range(of: needle))
            let before = source[..<firstUse.lowerBound]
            let opens = before.components(separatedBy: "#if os(iOS)").count - 1
            let closes = before.components(separatedBy: "#endif").count - 1
            #expect(opens > closes, "\(needle) must be inside #if os(iOS)")
        }
    }
}

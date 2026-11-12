import SwiftUI
import AVFoundation
import LowHangingFruitKit

// The Smooth Sweeper page: the header's broom opens it, and it is the only
// home of the Sweeper's settings (they left Profile on 2026-11-10). Three
// pieces, all in this file because they share their small parts: the page,
// the per-class page it pushes, and the pure helpers both read.
//
// Everything here writes through `NotificationScheduler`'s setters, which
// persist and reschedule on their own, so there is no Save step and nothing to
// replan on dismiss.

// MARK: - Pure helpers

/// The page's wording and arithmetic, off the Views so tests can call it and
/// no main-actor isolation follows it into a background caller (see the
/// `decidedText` trap in CLAUDE.md).
enum SweeperText {
    /// The bar fills over this long before the alarm.
    nonisolated static let progressWindow: TimeInterval = 4 * 3600

    /// `h:mm:ss`. Hours are not capped: work due in nine days reads
    /// `216:00:00`, which is true, where a clamp would lie.
    nonisolated static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// 0 when the alarm is four or more hours away, 1 when it rings.
    nonisolated static func progress(remaining: TimeInterval) -> Double {
        min(1, max(0, 1 - remaining / progressWindow))
    }

    /// "5m" ... "1h".
    nonisolated static func minutesLabel(_ minutes: Int) -> String {
        minutes == 60 ? "1h" : "\(minutes)m"
    }

    /// The one-line summary under a class that has chosen its own lead time or
    /// sound ("30m · gentle chime"); nil for a class on the defaults, so most
    /// rows stay a single line.
    nonisolated static func overrideSubtitle(_ settings: SweeperSettings, course: String) -> String? {
        let parts = [
            settings.minutesOverrides[course].map(minutesLabel),
            settings.soundOverrides[course]?.label,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Sound preview

/// Plays a sound once so a student can hear what they are choosing. The
/// previews play from the app bundle exactly as the old Profile row did; the
/// system alarm has no file and so no preview.
@MainActor
private final class SweeperSoundPreview: ObservableObject {
    private var player: AVAudioPlayer?

    func play(_ sound: SweeperSound) {
        stop()
        guard let filename = sound.filename,
              let url = Bundle.main.url(forResource: filename, withExtension: nil) else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

// MARK: - Shared pieces

/// Tomato-tinted playback button; icon only.
private struct SweeperPlayButton: View {
    let sound: SweeperSound
    let preview: SweeperSoundPreview
    var fill: Color = Color.smoothPaper
    var size: CGFloat = 38

    var body: some View {
        if sound.filename != nil {
            Button { preview.play(sound) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
                    .frame(width: size, height: size)
                    .background(Circle().fill(fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("preview \(sound.label)")
        }
    }
}

/// The on/off switch as one plain row, the same height and skin as the sound
/// row (Marco, 2026-11-11: the page had two titles, "Sweeper" and a 64pt
/// "on.", and the switch belongs under the card that shows the next alarm,
/// no bigger than any other row). The wrong fix is shrinking the old "on."
/// headline: it is still a second title, only a smaller one.
private struct SweeperSwitchRow: View {
    let label: String
    let binding: Binding<Bool>

    var body: some View {
        Toggle(isOn: binding) {
            Text("on")
                .font(.lhfSans(15))
                .foregroundStyle(Color.smoothInk)
        }
        .tint(Color.smoothTomato)
        .accessibilityLabel(label)
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Color.smoothSurface.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The beige pill of lead times, in the dashboard picker's skin with the
/// selected chip tomato-tinted. With `allowsDefault` a leading "default"
/// segment stands for `nil`.
private struct SweeperMinutePicker: View {
    @Binding var selection: Int?
    var allowsDefault = false
    @Namespace private var chip

    private var options: [Int?] {
        (allowsDefault ? [nil] : []) + NotificationScheduler.sweeperMinuteOptions.map { Optional($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isActive = option == selection
                let label = option.map(SweeperText.minutesLabel) ?? "default"
                Text(label)
                    .font(.lhfSans(14, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Color.smoothTomatoInk : Color.smoothMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: option == nil ? 60 : 0, maxWidth: .infinity)
                    .frame(height: 32)
                    .background {
                        if isActive {
                            Capsule()
                                .fill(Color.smoothTomato.opacity(0.22))
                                .matchedGeometryEffect(id: "active", in: chip)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .padding(.vertical, -6)
                    .onTapGesture {
                        guard option != selection else { return }
                        lhfHapticLight()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = option }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Color.smoothSurface.opacity(0.58), in: Capsule())
        .overlay { Capsule().stroke(Color.smoothRule.opacity(0.72), lineWidth: 1.25) }
    }
}

// MARK: - The page

struct SweeperView: View {
    /// Set the first time this page appears; the header's "new" dot reads it
    /// (`ContentView.sweeperButton`). A preference, so `UserDefaults.lhf`.
    static let pageSeenKey = "sweeperPageSeenV1"

    /// The dashboard's items as the sheet opened; the card reads them, the
    /// planner reads its own.
    let items: [DashItem]

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var scheduler: NotificationScheduler
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = SweeperSoundPreview()
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SmoothFormHeader(title: "Sweeper", accent: .smoothTomato, spark: .smoothMarigold)
                        .padding(.bottom, 4)

                    nextSweepCard
                        .padding(.top, 10)

                    SweeperSwitchRow(
                        label: "Smooth Sweeper",
                        binding: Binding(
                            get: { scheduler.loudAlertEnabled },
                            set: {
                                scheduler.setLoudAlertEnabled($0)
                                scheduler.rescheduleAfterPreferenceChange()
                            }
                        )
                    )
                    .padding(.top, 10)

                    if !scheduler.isEnabled {
                        Label("turn on due-date reminders in profile to use Smooth Sweeper.", systemImage: "bell.slash")
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.v2DateText)
                            .padding(.top, 8)
                    }

                    section("default")
                    SweeperMinutePicker(selection: Binding(
                        get: { scheduler.sweeperMinutes },
                        set: { if let minutes = $0 { scheduler.setSweeperMinutes(minutes) } }
                    ))
                    soundRow
                        .padding(.top, 10)

                    let courses = state.visibleCourseCodes()
                    if !courses.isEmpty {
                        section("classes")
                        VStack(spacing: 0) {
                            ForEach(courses, id: \.self) { course in
                                classRow(course)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Color.smoothPaper.ignoresSafeArea())
            .tint(Color.smoothTomato)
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { course in
                SweeperClassView(course: course, preview: preview)
                    .environmentObject(state)
                    .environmentObject(scheduler)
            }
        }
        .onAppear { UserDefaults.lhf.set(true, forKey: Self.pageSeenKey) }
        .onDisappear { preview.stop() }
    }

    private func section(_ title: String) -> some View {
        SmoothSectionHeader(title, accent: .smoothTomatoInk)
            .padding(.top, 24)
            .padding(.bottom, 10)
    }

    // MARK: Next sweep

    /// The soonest alarm that will ring. Re-asked every second from the
    /// timeline's own date, so the card rolls on to the next alarm by itself
    /// the moment one rings, with no timer of ours to keep in step.
    @ViewBuilder
    private var nextSweepCard: some View {
        if !scheduler.loudAlertEnabled || !scheduler.isEnabled {
            HStack(spacing: 7) {
                Circle().fill(Color.smoothRule).frame(width: 8, height: 8)
                Text("nothing set")
                    .font(.lhfMono(10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.smoothMuted)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Color.smoothSurface.opacity(0.4), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let ring = scheduler.nextSweep(in: items, now: context.date) {
                    SweepCard(ring: ring, now: context.date,
                              courseName: state.courseDisplayName(ring.item.assignment.course),
                              preview: preview)
                }
            }
        }
    }

    // MARK: Default sound

    private var soundRow: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("sound", selection: Binding(
                    get: { scheduler.sweeperSound },
                    set: { scheduler.setSweeperSound($0) }
                )) {
                    ForEach(SweeperSound.allCases) { sound in
                        Text(sound.label).tag(sound)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.smoothInk)
                    Text(scheduler.sweeperSound.label)
                        .font(.lhfSans(15))
                        .foregroundStyle(Color.smoothInk)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("sound, \(scheduler.sweeperSound.label)")

            SweeperPlayButton(sound: scheduler.sweeperSound, preview: preview)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 50)
        .background(Color.smoothSurface.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Classes

    private func classRow(_ course: String) -> some View {
        let included = !scheduler.sweeperExcludedCourses.contains(course)
        let subtitle = SweeperText.overrideSubtitle(scheduler.sweeperSettings, course: course)
        return HStack(spacing: 12) {
            Button { path.append(course) } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(included ? courseAccent(for: course) : Color.smoothRule)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.courseDisplayName(course))
                            .font(.lhfSans(15, weight: included ? .semibold : .medium))
                            .foregroundStyle(included ? Color.smoothInk : Color.smoothMuted)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.lhfMono(11))
                                .foregroundStyle(courseAccentInk(for: course))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([state.courseDisplayName(course), subtitle].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("open settings for this class")

            Toggle("sweep \(state.courseDisplayName(course))", isOn: Binding(
                get: { included },
                set: { scheduler.setSweeperCourse(course, enabled: $0) }
            ))
            .labelsHidden()
            .tint(Color.smoothTomato)

            Button { path.append(course) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.smoothRule)
                    .frame(width: 20, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .frame(minHeight: 60)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.smoothRule.opacity(0.35)).frame(height: 1)
        }
    }
}

/// The live card: pulsing dot and course, the alarm's sound preview, the
/// work's title, a ticking countdown and the clock time it rings, and a bar
/// that fills over the last four hours. Dressed like the dashboard's card for
/// the same work (`smoothTaskFill`), so it reads as that card with the alarm
/// laid over it.
private struct SweepCard: View {
    let ring: SweepRing
    let now: Date
    let courseName: String
    let preview: SweeperSoundPreview

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var ink: Color { smoothTaskTextAccent(ring.item.due, now: now) }

    var body: some View {
        let remaining = ring.ringAt.timeIntervalSince(now)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.smoothTomato)
                        .frame(width: 8, height: 8)
                        .background(
                            Circle()
                                .fill(Color.smoothTomato.opacity(pulse ? 0 : 0.6))
                                .scaleEffect(pulse ? 2.4 : 1)
                        )
                    Text(courseName)
                        .font(.lhfMono(10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(ink)
                        .lineLimit(1)
                }
                Spacer()
                SweeperPlayButton(sound: ring.sound, preview: preview,
                                  fill: Color.smoothPaper.opacity(0.7), size: 30)
            }
            Text(ring.item.assignment.title)
                .font(.lhfSerif(18))
                .foregroundStyle(Color.smoothInk)
                .lineLimit(2)
                .padding(.top, 8)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(SweeperText.countdown(remaining))
                    .font(.lhfMono(34, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.smoothInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("rings \(Self.clock(ring.ringAt, now: now))")
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.smoothInk.opacity(0.68))
                    .lineLimit(1)
            }
            .padding(.top, 4)
            GeometryReader { geo in
                Capsule().fill(Color.smoothPaper.opacity(0.6))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.smoothTomato)
                            .frame(width: geo.size.width * SweeperText.progress(remaining: remaining))
                    }
            }
            .frame(height: 6)
            .padding(.top, 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(smoothTaskFill(ring.item.due, now: now), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    /// "11:29 pm", with the weekday in front once it is not today.
    private static func clock(_ date: Date, now: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened).lowercased()
        if Calendar.current.isDate(date, inSameDayAs: now) { return time }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
}

// MARK: - One class

struct SweeperClassView: View {
    let course: String
    fileprivate let preview: SweeperSoundPreview

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var scheduler: NotificationScheduler

    private var included: Bool { !scheduler.sweeperExcludedCourses.contains(course) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SmoothFormHeader(title: state.courseDisplayName(course),
                                 accent: .smoothTomato, spark: .smoothMarigold)
                    .padding(.bottom, 4)

                SweeperSwitchRow(
                    label: "sweep \(state.courseDisplayName(course))",
                    binding: Binding(
                        get: { included },
                        set: { scheduler.setSweeperCourse(course, enabled: $0) }
                    )
                )
                .padding(.top, 10)

                // Dimmed, not disabled, while the class is off: a student can
                // still set up the class before switching it back on.
                Group {
                    section("ring")
                    SweeperMinutePicker(
                        selection: Binding(
                            get: { scheduler.sweeperMinutesOverrides[course] },
                            set: { scheduler.setSweeperCourseMinutes(course, minutes: $0) }
                        ),
                        allowsDefault: true
                    )

                    section("sound")
                    VStack(spacing: 0) {
                        soundRow(nil)
                        ForEach(SweeperSound.allCases) { sound in
                            soundRow(sound)
                        }
                    }

                    Button {
                        scheduler.resetSweeperCourseOverrides(course)
                    } label: {
                        Text("reset")
                            .font(.lhfSans(14, weight: .semibold))
                            .foregroundStyle(Color.smoothInk)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.smoothRule, lineWidth: 1.25)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!scheduler.sweeperSettings.hasOverride(course))
                    .opacity(scheduler.sweeperSettings.hasOverride(course) ? 1 : 0.45)
                    .padding(.top, 26)
                }
                .opacity(included ? 1 : 0.5)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Color.smoothPaper.ignoresSafeArea())
        .tint(Color.smoothTomato)
        .navigationTitle("")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private func section(_ title: String) -> some View {
        SmoothSectionHeader(title, accent: .smoothTomatoInk)
            .padding(.top, 24)
            .padding(.bottom, 10)
    }

    /// One radio row; `nil` is "default".
    private func soundRow(_ sound: SweeperSound?) -> some View {
        let selected = scheduler.sweeperSoundOverrides[course] == sound
        return HStack(spacing: 12) {
            Button {
                scheduler.setSweeperCourseSound(course, sound: sound)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(selected ? Color.smoothTomato : Color.smoothRule, lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                        if selected {
                            Circle().fill(Color.smoothTomato).frame(width: 12, height: 12)
                        }
                    }
                    Text(sound?.label ?? "default")
                        .font(.lhfSans(15, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Color.smoothInk)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sound?.label ?? "default")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)

            if let sound {
                SweeperPlayButton(sound: sound, preview: preview,
                                  fill: Color.smoothSurface.opacity(0.4), size: 38)
            }
        }
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.smoothRule.opacity(0.35)).frame(height: 1)
        }
    }
}

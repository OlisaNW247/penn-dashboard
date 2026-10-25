import SwiftUI
import AVFoundation

struct SweeperSettingsSection: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var scheduler: NotificationScheduler

    @State private var preview: AVAudioPlayer?

    var body: some View {
        Section {
            Toggle("Smooth Sweeper", isOn: Binding(
                get: { scheduler.loudAlertEnabled },
                set: {
                    scheduler.setLoudAlertEnabled($0)
                    scheduler.rescheduleAfterPreferenceChange()
                }
            ))
            if scheduler.loudAlertEnabled {
                Picker("alert timing", selection: Binding(
                    get: { scheduler.sweeperMinutes },
                    set: { scheduler.setSweeperMinutes($0) }
                )) {
                    ForEach(NotificationScheduler.sweeperMinuteOptions, id: \.self) { minutes in
                        Text("\(minutes) minutes before").tag(minutes)
                    }
                }
                Picker("audio", selection: Binding(
                    get: { scheduler.sweeperSound },
                    set: { scheduler.setSweeperSound($0) }
                )) {
                    ForEach(SweeperSound.allCases) { sound in
                        Text(sound.label).tag(sound)
                    }
                }
                if scheduler.sweeperSound.filename != nil {
                    Button("preview audio", systemImage: "play.circle") {
                        preview?.stop()
                        guard let filename = scheduler.sweeperSound.filename,
                              let url = Bundle.main.url(forResource: filename, withExtension: nil) else { return }
                        preview = try? AVAudioPlayer(contentsOf: url)
                        preview?.play()
                    }
                }
                DisclosureGroup {
                    Toggle("all classes", isOn: Binding(
                        get: { scheduler.sweeperExcludedCourses.isEmpty },
                        set: { all in
                            if all { scheduler.resetSweeperCourses() }
                            else {
                                scheduler.excludeSweeperCourses(state.visibleCourseCodes())
                            }
                        }
                    ))
                    ForEach(state.visibleCourseCodes(), id: \.self) { course in
                        Toggle(state.courseDisplayName(course), isOn: Binding(
                            get: { !scheduler.sweeperExcludedCourses.contains(course) },
                            set: { scheduler.setSweeperCourse(course, enabled: $0) }
                        ))
                    }
                    if state.visibleCourseCodes().isEmpty {
                        Text("your classes will appear here when you connect Canvas.")
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.v2DateText)
                    }
                } label: {
                    HStack {
                        Text("classes")
                        Spacer()
                        Text(scheduler.sweeperExcludedCourses.isEmpty ? "all classes" : "custom")
                            .foregroundStyle(Color.v2DateText)
                    }
                }
                if !scheduler.isEnabled {
                    Label("turn on due-date reminders above to use Smooth Sweeper.", systemImage: "bell.slash")
                        .font(.lhfSecondary(12))
                        .foregroundStyle(Color.v2DateText)
                }
            }
        } header: {
            SmoothSectionHeader("smooth sweeper", accent: .smoothTomato)
        }
        .smoothSectionBackground(.smoothTomato)
        .onChange(of: scheduler.sweeperSound) { preview?.stop() }
        .onChange(of: scheduler.loudAlertEnabled) { preview?.stop() }
        .onDisappear { preview?.stop() }
    }
}

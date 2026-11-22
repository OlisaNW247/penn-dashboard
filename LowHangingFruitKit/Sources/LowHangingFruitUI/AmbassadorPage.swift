import SwiftUI
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Profile → ambassador. Signed out it asks for the code; signed in it is the
/// ambassador's four tasks (Marco, 2026-11-21: the page had grown into a wall
/// of sections, so it is now the few things an ambassador actually does):
/// anonymous chats, group chats, posters and feedback, each a row that opens
/// its own view (`AmbassadorTaskSheets.swift`) where it is done and ticked.
/// Under them the numbers, the reminder and the account rows. A first sign-in
/// opens a short intro sheet (`AmbassadorIntroView`).
///
/// Same chrome as the rest of Profile: a `Form`, `SmoothSectionHeader`s,
/// tinted section backgrounds, `lhfSecondary` type, lowercase, and the copy
/// rule (the least text that works).
///
/// Pushed from Profile onto the dashboard's stack (`DashRoute.ambassador`),
/// so it has a back button and no stack of its own, like Profile.
struct AmbassadorPage: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var model = AmbassadorModel.shared
    @Environment(\.openURL) private var openURL

    @State private var codeField = ""
    @State private var openTask: AmbassadorTask?

    var body: some View {
        Form {
            Section {
                SmoothFormHeader(title: "Ambassador", accent: .smoothGrape, spark: .smoothMarigold)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .listRowSeparator(.hidden)

            if model.isSignedIn {
                goalSection
                tasksSection
                numbersSection
                remindersSection
                accountSection
            } else {
                signInSection
            }
        }
        .formStyle(.grouped)
        .font(.lhfSecondary(15))
        .foregroundStyle(Color.smoothInk)
        .smoothFormChrome(accent: .smoothGrape)
        .navigationTitle("")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task { await model.refreshIfStale() }
        // The plan is kept for half an hour, and the posts in it are the
        // server's. On 2026-11-19 Olisa had the written posts removed, the
        // server changed within minutes, and his phone went on showing the
        // old six with nothing he could do about it. A pull asks again;
        // signed out it does nothing (`refresh` returns without a code).
        .refreshable { await model.refresh() }
        .sheet(item: $openTask) { task in
            AmbassadorTaskSheet(task: task)
        }
        .sheet(isPresented: Binding(
            get: { model.introPending },
            set: { if !$0 { model.finishIntro() } }
        )) {
            AmbassadorIntroView()
        }
        .lhfSheetTheme()
        .frame(minWidth: 360, minHeight: 420)
    }

    // MARK: Sign in

    private var signInSection: some View {
        Section {
            TextField("your ambassador code", text: $codeField)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .submitLabel(.go)
#endif
                .onSubmit { signIn() }
            HStack {
                Button("sign in") { signIn() }
                    .disabled(model.isWorking || codeField.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("paste") { pasteCode() }
                    .buttonStyle(.borderless)
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            if let error = model.lastError {
                Text(error)
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.smoothTomatoInk)
            }
        } header: {
            SmoothSectionHeader("sign in", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothGrape)
    }

    private func signIn() {
        let raw = codeField
        Task {
            if await model.signIn(raw) { codeField = "" }
        }
    }

    private func pasteCode() {
        #if canImport(UIKit)
        if let s = UIPasteboard.general.string { codeField = s }
        #elseif canImport(AppKit)
        if let s = NSPasteboard.general.string(forType: .string) { codeField = s }
        #endif
    }

    // MARK: The goal

    /// Downloads at the ambassador's school toward 100, first on the page
    /// (Marco, 2026-11-22). No section at all until the server sends the count.
    @ViewBuilder
    private var goalSection: some View {
        if let plan = model.plan, let installs = plan.numbers?.schoolInstalls {
            Section {
                AmbassadorGoalLine(label: "downloads at \(plan.schoolLabel)", count: installs,
                                   target: AmbassadorGoals.downloadsTarget)
            }
            .smoothSectionBackground(.smoothTeal)
        }
    }

    // MARK: The tasks

    private var tasksSection: some View {
        Section {
            ForEach(AmbassadorTask.allCases) { task in
                taskRow(task)
            }
        } header: {
            SmoothSectionHeader("your job", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothGrape)
    }

    private func taskRow(_ task: AmbassadorTask) -> some View {
        // Posters never finish short of the goal, so the row says how far
        // along it is instead of ticking.
        let trailing = task == .posters
            ? AmbassadorGoals.caption(count: model.postersPutUp, target: AmbassadorGoals.postersTarget)
            : nil
        return AmbassadorRow(label: task.label, symbol: task.symbol, trailing: trailing, leaves: false,
                      done: model.isDone(task)) {
            model.clearError()
            openTask = task
        }
    }

    // MARK: Numbers

    @ViewBuilder
    private var numbersSection: some View {
        if let plan = model.plan, let n = plan.numbers {
            Section {
                numberRow("your link opens", n.linkOpens, recent: n.linkOpensRecent, days: n.days)
                numberRow("\(plan.schoolLabel) poster scans", n.schoolScans, recent: n.schoolScansRecent, days: n.days)
                if let installs = n.schoolInstalls {
                    numberRow("\(plan.schoolLabel) downloads", installs, recent: n.schoolInstallsRecent, days: n.days)
                }
                numberRow("posts logged", n.posts, recent: nil, days: n.days)
            } header: {
                SmoothSectionHeader("numbers", accent: .smoothCobalt)
            }
            .smoothSectionBackground(.smoothTeal)
        }
    }

    private func numberRow(_ label: String, _ value: Int, recent: Int?, days: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text("\(value)")
                .font(.lhfMono(15, weight: .semibold))
            if let recent {
                Text("\u{00B7} \(recent) in \(days)d")
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.v2DateText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section {
            Picker("reminder", selection: Binding(
                get: { model.cadence },
                set: { newValue in Task { await model.setCadence(newValue) } }
            )) {
                ForEach(AmbassadorReminderCadence.offered) { cadence in
                    Text(cadence.label).tag(cadence)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.cadence != .off {
                DatePicker("time", selection: reminderTimeBinding, displayedComponents: .hourAndMinute)
                if model.authStatus == .denied {
                    Label("notifications are off in system settings.", systemImage: "bell.slash")
                        .font(.lhfSecondary(12))
                        .foregroundStyle(Color.v2DateText)
                }
            }
        } header: {
            SmoothSectionHeader("reminder", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothTomato)
    }

    /// Hour and minute as a `Date` for the picker, today's date for the rest.
    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: model.reminderHour, minute: model.reminderMinute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                Task { await model.setReminderTime(hour: parts.hour ?? AmbassadorReminders.defaultHour,
                                                   minute: parts.minute ?? 0) }
            }
        )
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            if let page = model.plan?.page, let url = URL(string: page) {
                Button {
                    openURL(url)
                } label: {
                    HStack {
                        Text("my web page \u{2197}")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.plan?.isPaused() == true {
                Button("resume reminders") { Task { await model.pause(weeks: 0) } }
            } else {
                Button("pause everything for 4 weeks") { Task { await model.pause(weeks: 4) } }
            }
            Button("sign out", role: .destructive) { model.signOut() }
        } header: {
            SmoothSectionHeader(model.statusLine, accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothMarigold)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AmbassadorPage()
            .environmentObject(AppState())
    }
}
#endif

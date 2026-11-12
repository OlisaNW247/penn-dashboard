import SwiftUI
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Profile → ambassador. Signed out it asks for the code; signed in it is the
/// closed loop the founders asked for on 2026-11-09: a daily local reminder,
/// the post for today already written with the ambassador's own tracked link,
/// one tap to copy it, one to say it went out, and their numbers moving
/// underneath. The rest (the other messages, feedback, pause, sign out) is
/// below the fold.
///
/// The page opens on the job itself and the ambassador's web page (Olisa,
/// from his phone, 2026-11-12: the job is spamming chats, putting up posters
/// and getting Smooth in front of as many eyes as possible, and the web page
/// is the centre piece). There was a "getting started" checklist here until
/// that day; its first step was "download smooth and connect canvas", shown
/// to someone already signed in to the app, and he had the whole list removed.
/// The server still sends `checklist` in the plan, and nothing here reads it.
///
/// Same chrome as the rest of Profile: a `Form`, `SmoothSectionHeader`s,
/// tinted section backgrounds, `lhfSecondary` type, lowercase, and the copy
/// rule (the least text that works). The one paragraph of real text on the
/// page is the post itself, which is content, not chrome.
///
/// Pushed from Profile onto the dashboard's stack (`DashRoute.ambassador`),
/// so it has a back button and no stack of its own, like Profile.
struct AmbassadorPage: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var model = AmbassadorModel.shared
    @Environment(\.openURL) private var openURL

    @State private var codeField = ""
    @State private var feedbackText = ""
    @State private var copied = false
    @State private var feedbackSent = false
    @State private var showMessages = false
    @State private var showTips = false
    @State private var showPosters = false
    @State private var showIdea = false

    var body: some View {
        Form {
            Section {
                SmoothFormHeader(title: "Ambassador", accent: .smoothGrape, spark: .smoothMarigold)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .listRowSeparator(.hidden)

            if model.isSignedIn {
                jobSection
                todaySection
                postersSection
                numbersSection
                remindersSection
                messagesSection
                feedbackSection
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
        .sheet(isPresented: $showPosters) {
            if let plan = model.plan {
                AmbassadorPostersView(posters: plan.posters ?? [], schoolLabel: plan.schoolLabel)
            }
        }
        .sheet(isPresented: $showIdea) {
            PosterIdeaSheet()
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
            Text("it\u{2019}s in the text from marco or olisa. no account needed.")
                .font(.lhfSecondary(12))
                .foregroundStyle(Color.v2DateText)
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

    // MARK: The job

    /// What an ambassador is for, in one line, and the way to their web page,
    /// which holds everything (links, posters, stickers, numbers). First on
    /// the page so nobody has to scroll to learn either.
    private var jobSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("get smooth in front of as many eyes as you can.")
                    .font(.lhfSecondary(17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("spam the chats. put up posters. post every day.")
                    .font(.lhfSecondary(14))
                    .foregroundStyle(Color.v2DateText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            if let page = model.plan?.page, let url = URL(string: page) {
                Button {
                    openURL(url)
                } label: {
                    HStack {
                        Text("open my web page \u{2197}")
                            .font(.lhfSecondary(15, weight: .semibold))
                        Spacer()
                        Text("links \u{00B7} posters \u{00B7} stickers")
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.v2DateText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            SmoothSectionHeader("the job", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothLemon)
    }

    // MARK: Today

    @ViewBuilder
    private var todaySection: some View {
        Section {
            if let today = model.plan?.today {
                HStack(alignment: .firstTextBaseline) {
                    Text(today.isRest ? "rest day" : today.platform)
                        .font(.lhfSecondary(15, weight: .semibold))
                    Spacer()
                    if model.postedToday {
                        Label("posted", systemImage: "checkmark")
                            .font(.lhfSecondary(12, weight: .medium))
                            .foregroundStyle(Color.smoothTealInk)
                    }
                }
                Text(today.text)
                    .font(.lhfSecondary(15))
                    .foregroundStyle(Color.smoothInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.smoothSurface))
                    .listRowSeparator(.hidden)
                if !today.isRest {
                    HStack(spacing: 10) {
                        Button {
                            copy(today.text)
                        } label: {
                            Label(copied ? "copied" : "copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.smoothGrape)
                        Button {
                            Task { await model.markPostedToday() }
                        } label: {
                            Label(model.postedToday ? "posted" : "i posted it", systemImage: "paperplane")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.postedToday || model.isWorking)
                    }
                    .font(.lhfSecondary(14, weight: .semibold))
                }
            } else if model.isWorking {
                ProgressView().controlSize(.small)
            } else {
                Text(model.lastError ?? "couldn\u{2019}t load today\u{2019}s post")
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.v2DateText)
            }
            if let error = model.lastError, model.plan?.today != nil {
                Text(error)
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.smoothTomatoInk)
            }
        } header: {
            SmoothSectionHeader("today", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothGrape)
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        lhfHapticLight()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    // MARK: Posters

    /// Where the posters, the live dashboard and the idea box are. Each row
    /// says by its trailing mark whether it stays in the app (a chevron, or a
    /// count) or leaves it (the arrow, and the label says so too).
    private var postersSection: some View {
        Section {
            if let posters = model.plan?.posters, !posters.isEmpty {
                posterRow("all posters", symbol: "photo.on.rectangle.angled", trailing: "\(posters.count)", leaves: false) {
                    showPosters = true
                }
            }
            if let dashboard = model.plan?.dashboardURL {
                posterRow("scan dashboard \u{2197}", symbol: "chart.bar", trailing: nil, leaves: true) {
                    openURL(dashboard)
                }
            }
            posterRow("send a poster idea", symbol: "lightbulb", trailing: ideasCount, leaves: false) {
                model.clearError()
                showIdea = true
            }
        } header: {
            SmoothSectionHeader("posters", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothMarigold)
    }

    /// "3 of 30", or just the count when the server gives no limit, or nil.
    private var ideasCount: String? {
        guard let ideas = model.plan?.ideas else { return nil }
        if let limit = ideas.limit { return "\(ideas.sent) of \(limit)" }
        return "\(ideas.sent)"
    }

    private func posterRow(_ label: String, symbol: String, trailing: String?, leaves: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(Color.smoothInk)
                Text(label)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.lhfMono(13, weight: .medium))
                        .foregroundStyle(Color.v2DateText)
                }
                if !leaves {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.v2DateText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Numbers

    @ViewBuilder
    private var numbersSection: some View {
        if let plan = model.plan, let n = plan.numbers {
            Section {
                numberRow("your link opens", n.linkOpens, recent: n.linkOpensRecent, days: n.days)
                numberRow("\(plan.schoolLabel) poster scans", n.schoolScans, recent: n.schoolScansRecent, days: n.days)
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
                ForEach(AmbassadorReminderCadence.allCases) { cadence in
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

            Picker("my anonymous app", selection: Binding(
                get: { model.anonApp },
                set: { newValue in Task { await model.setAnonApp(newValue) } }
            )) {
                ForEach(AmbassadorAnonApp.allCases) { app in
                    Text(app.label).tag(app)
                }
            }
        } header: {
            SmoothSectionHeader("daily reminder", accent: .smoothCobalt)
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

    // MARK: The other messages

    @ViewBuilder
    private var messagesSection: some View {
        if let messages = model.plan?.messages, !messages.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showMessages) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(message.label)
                                    .font(.lhfSecondary(13, weight: .semibold))
                                Spacer()
                                Button("copy") { copy(message.text) }
                                    .buttonStyle(.borderless)
                                    .font(.lhfSecondary(13, weight: .semibold))
                            }
                            Text(message.text)
                                .font(.lhfSecondary(13))
                                .foregroundStyle(Color.v2DateText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                } label: {
                    Text("more messages")
                }
                if let tips = model.plan?.tips, !tips.isEmpty {
                    DisclosureGroup(isExpanded: $showTips) {
                        ForEach(tips, id: \.self) { tip in
                            Text(tip)
                                .font(.lhfSecondary(13))
                                .foregroundStyle(Color.v2DateText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } label: {
                        Text("posting tips")
                    }
                }
            } header: {
                SmoothSectionHeader("messages", accent: .smoothCobalt)
            }
            .smoothSectionBackground(.smoothCobalt)
        }
    }

    // MARK: Feedback

    private var feedbackSection: some View {
        Section {
            TextField("tell the founders something", text: $feedbackText, axis: .vertical)
                .lineLimit(2...6)
            HStack {
                Button(feedbackSent ? "sent" : "send") {
                    let text = feedbackText
                    Task {
                        if await model.sendFeedback(text) {
                            feedbackText = ""
                            feedbackSent = true
                            try? await Task.sleep(for: .seconds(2))
                            feedbackSent = false
                        }
                    }
                }
                .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                Spacer()
            }
        } header: {
            SmoothSectionHeader("feedback", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothCobalt)
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
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

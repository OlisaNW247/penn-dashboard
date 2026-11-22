import SwiftUI
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The four task views behind the ambassador page's "your job" rows (Marco,
/// 2026-11-21). Each is a `Form` in the page's own chrome with the task's name
/// as its header, what the ambassador needs to do it, and a "done" that ticks
/// the row on the page (feedback ticks itself when it sends).

/// Copy to the pasteboard, with the light haptic the page used.
@MainActor
enum AmbassadorPasteboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        lhfHapticLight()
    }
}

/// The rounded box a post sits in. Line breaks are kept: a "list" post is its
/// line breaks.
struct AmbassadorPostBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.lhfSecondary(15))
            .foregroundStyle(Color.smoothInk)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.smoothSurface))
            .listRowSeparator(.hidden)
    }
}

/// A button that says "copied" for a moment after it copies.
struct AmbassadorCopyButton: View {
    let label: String
    let text: String
    var prominent = false
    @State private var copied = false

    var body: some View {
        let button = Button {
            AmbassadorPasteboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        if prominent {
            button.buttonStyle(.borderedProminent).tint(Color.smoothGrape)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// The follow-up reply under a post, with its own copy button. Nothing when
/// the server sent none (an older server) or an empty one.
struct AmbassadorReplyBlock: View {
    let reply: String?

    var body: some View {
        if let reply, !reply.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("then reply:")
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.v2DateText)
                Text(reply)
                    .font(.lhfSecondary(13))
                    .foregroundStyle(Color.v2DateText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                AmbassadorCopyButton(label: "copy reply", text: reply)
                    .font(.lhfSecondary(14, weight: .semibold))
            }
        }
    }
}

/// The shared frame: the page's chrome, the task's name in the header, a
/// close that works on the Mac too.
private struct AmbassadorTaskForm<Content: View>: View {
    let task: AmbassadorTask
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form {
            Section {
                SmoothFormHeader(title: task.label, accent: .smoothGrape, spark: .smoothMarigold)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .listRowSeparator(.hidden)
            content()
        }
        .formStyle(.grouped)
        .font(.lhfSecondary(15))
        .foregroundStyle(Color.smoothInk)
        .smoothFormChrome(accent: .smoothGrape)
        .lhfSheetTheme()
        .frame(minWidth: 360, minHeight: 420)
    }
}

/// The "done" row: a filled grape button, then a disabled check once it is.
private struct AmbassadorDoneRow: View {
    let task: AmbassadorTask
    @ObservedObject var model: AmbassadorModel

    var body: some View {
        Section {
            if model.isDone(task) {
                Label("done", systemImage: "checkmark")
                    .font(.lhfSecondary(15, weight: .semibold))
                    .foregroundStyle(Color.smoothTealInk)
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    Task { await model.markDone(task) }
                } label: {
                    Text("done")
                        .font(.lhfSecondary(15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.smoothGrape)
                .disabled(model.isWorking)
            }
        }
        .listRowBackground(Color.clear)
    }
}

/// Picks the view for a task; what the page's `.sheet(item:)` shows.
struct AmbassadorTaskSheet: View {
    let task: AmbassadorTask

    var body: some View {
        switch task {
        case .anonChats: AmbassadorAnonChatsSheet()
        case .groupChats: AmbassadorGroupChatsSheet()
        case .posters: AmbassadorPostersTaskSheet()
        case .feedback: AmbassadorFeedbackSheet()
        }
    }
}

// MARK: Anonymous chats

struct AmbassadorAnonChatsSheet: View {
    @ObservedObject private var model = AmbassadorModel.shared
    @State private var showMessages = false
    @State private var showTips = false

    var body: some View {
        AmbassadorTaskForm(task: .anonChats) {
            Section {
                if let today = model.plan?.today {
                    Text(today.isRest ? "rest day" : today.platform)
                        .font(.lhfSecondary(15, weight: .semibold))
                    AmbassadorPostBox(text: today.text)
                    if !today.isRest {
                        AmbassadorReplyBlock(reply: today.reply)
                        AmbassadorCopyButton(label: "copy", text: today.text, prominent: true)
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
                Picker("my anonymous app", selection: Binding(
                    get: { model.anonApp },
                    set: { newValue in Task { await model.setAnonApp(newValue) } }
                )) {
                    ForEach(AmbassadorAnonApp.allCases) { app in
                        Text(app.label).tag(app)
                    }
                }
            }
            .smoothSectionBackground(.smoothGrape)

            if let suggestions = model.plan?.suggested, !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 8) {
                            AmbassadorPostBox(text: suggestion.text)
                            HStack(spacing: 10) {
                                AmbassadorCopyButton(label: "copy", text: suggestion.text, prominent: true)
                                if let reply = suggestion.reply, !reply.isEmpty {
                                    AmbassadorCopyButton(label: "copy reply", text: reply)
                                }
                            }
                            .font(.lhfSecondary(14, weight: .semibold))
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    SmoothSectionHeader("from the founders", accent: .smoothCobalt)
                }
                .smoothSectionBackground(.smoothGrape)
            }

            if let messages = model.plan?.messages, !messages.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showMessages) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(message.label)
                                        .font(.lhfSecondary(13, weight: .semibold))
                                    Spacer()
                                    AmbassadorCopyButton(label: "copy", text: message.text)
                                        .buttonStyle(.borderless)
                                        .font(.lhfSecondary(13, weight: .semibold))
                                }
                                Text(message.text)
                                    .font(.lhfSecondary(13))
                                    .foregroundStyle(Color.v2DateText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                AmbassadorReplyBlock(reply: message.reply)
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
                }
                .smoothSectionBackground(.smoothCobalt)
            }

            AmbassadorDoneRow(task: .anonChats, model: model)
        }
    }
}

// MARK: Group chats

struct AmbassadorGroupChatsSheet: View {
    @ObservedObject private var model = AmbassadorModel.shared

    /// The ambassador's own tracked link for group chats; the App Store page
    /// when the server sent none (an older server).
    private var link: String? {
        model.plan?.links?["gc"] ?? model.plan?.appStore
    }

    var body: some View {
        AmbassadorTaskForm(task: .groupChats) {
            Section {
                Text("drop the link in every group chat you\u{2019}re in.")
                    .font(.lhfSecondary(14))
                    .foregroundStyle(Color.v2DateText)
                    .fixedSize(horizontal: false, vertical: true)
                if let link {
                    AmbassadorPostBox(text: link)
                    AmbassadorCopyButton(label: "copy link", text: link, prominent: true)
                        .font(.lhfSecondary(14, weight: .semibold))
                }
            }
            .smoothSectionBackground(.smoothGrape)
            AmbassadorDoneRow(task: .groupChats, model: model)
        }
    }
}

// MARK: Posters

struct AmbassadorPostersTaskSheet: View {
    @ObservedObject private var model = AmbassadorModel.shared
    @Environment(\.openURL) private var openURL
    @State private var showPosters = false
    @State private var showIdea = false

    var body: some View {
        AmbassadorTaskForm(task: .posters) {
            Section {
                if let posters = model.plan?.posters, !posters.isEmpty {
                    row("all posters", symbol: "photo.on.rectangle.angled", trailing: "\(posters.count)", leaves: false) {
                        showPosters = true
                    }
                }
                if let dashboard = model.plan?.dashboardURL {
                    row("scan dashboard \u{2197}", symbol: "chart.bar", trailing: nil, leaves: true) {
                        openURL(dashboard)
                    }
                }
                row("send a poster idea", symbol: "lightbulb", trailing: ideasCount, leaves: false) {
                    model.clearError()
                    showIdea = true
                }
            }
            .smoothSectionBackground(.smoothMarigold)
            AmbassadorDoneRow(task: .posters, model: model)
        }
        .sheet(isPresented: $showPosters) {
            if let plan = model.plan {
                AmbassadorPostersView(posters: plan.posters ?? [], schoolLabel: plan.schoolLabel)
            }
        }
        .sheet(isPresented: $showIdea) {
            PosterIdeaSheet()
        }
    }

    /// "3 of 30", or just the count when the server gives no limit, or nil.
    private var ideasCount: String? {
        guard let ideas = model.plan?.ideas else { return nil }
        if let limit = ideas.limit { return "\(ideas.sent) of \(limit)" }
        return "\(ideas.sent)"
    }

    private func row(_ label: String, symbol: String, trailing: String?, leaves: Bool,
                     action: @escaping () -> Void) -> some View {
        AmbassadorRow(label: label, symbol: symbol, trailing: trailing, leaves: leaves, done: false, action: action)
    }
}

// MARK: Feedback

struct AmbassadorFeedbackSheet: View {
    @ObservedObject private var model = AmbassadorModel.shared
    @State private var text = ""
    @State private var sent = false

    var body: some View {
        AmbassadorTaskForm(task: .feedback) {
            Section {
                TextField("what people said, what broke, ideas for smooth", text: $text, axis: .vertical)
                    .lineLimit(2...6)
                HStack {
                    Button(sent ? "sent" : "send") {
                        let body = text
                        Task {
                            if await model.sendFeedback(body) {
                                text = ""
                                sent = true
                                try? await Task.sleep(for: .seconds(2))
                                sent = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.smoothGrape)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                    Spacer()
                    if model.isDone(.feedback) {
                        Label("done", systemImage: "checkmark")
                            .font(.lhfSecondary(12, weight: .medium))
                            .foregroundStyle(Color.smoothTealInk)
                    }
                }
                if let error = model.lastError {
                    Text(error)
                        .font(.lhfSecondary(12))
                        .foregroundStyle(Color.smoothTomatoInk)
                }
            }
            .smoothSectionBackground(.smoothCobalt)
        }
    }
}

/// A tappable row with a symbol, a label, an optional trailing count, an
/// optional teal tick, and a chevron (or nothing, for a row that leaves the
/// app, whose label carries the arrow). The page's task rows and the posters
/// task share it.
struct AmbassadorRow: View {
    let label: String
    let symbol: String
    let trailing: String?
    let leaves: Bool
    let done: Bool
    let action: () -> Void

    var body: some View {
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
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.smoothTealInk)
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
}

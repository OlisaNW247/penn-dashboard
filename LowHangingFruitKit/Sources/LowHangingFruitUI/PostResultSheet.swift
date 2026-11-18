import SwiftUI
import LowHangingFruitKit
import ImageIO
#if canImport(PhotosUI)
import PhotosUI
#endif

/// "how did a post do": a screenshot of a post the ambassador made, where it
/// went, what kind of post it was and, if they want, the numbers.
///
/// What leaves the phone, and only when the student taps "send": the
/// screenshot, shrunk and re-encoded as a JPEG with no metadata
/// (`PosterIdeaImage`), the two choices, the numbers and the note they typed.
/// Choosing a screenshot sends nothing.
struct PostResultSheet: View {
    @ObservedObject private var model = AmbassadorModel.shared
    @Environment(\.dismiss) private var dismiss

    /// The kinds the server lists, or these four when it lists none.
    private static let fallbackStyles: [AmbassadorPlan.Captures.Style] = [
        .init(key: "question", label: "question"),
        .init(key: "list", label: "slipped into a list"),
        .init(key: "pitch", label: "straight pitch"),
        .init(key: "other", label: "something else"),
    ]

    private static let platforms: [(key: String, label: String)] = [
        ("fizz", "fizz"), ("sidechat", "sidechat"), ("yikyak", "yik yak"), ("other", "other"),
    ]

    @State private var imageData: Data?
    @State private var previewImage: CGImage?
    @State private var platform = "sidechat"
    @State private var style = "question"
    @State private var upvotes = ""
    @State private var views = ""
    @State private var note = ""
    @State private var isSending = false
#if canImport(PhotosUI)
    @State private var pickerItem: PhotosPickerItem?
#endif

    private var styles: [AmbassadorPlan.Captures.Style] {
        if let listed = model.plan?.captures?.styles, !listed.isEmpty { return listed }
        return Self.fallbackStyles
    }

    private var canSend: Bool { !isSending && imageData != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
#if canImport(PhotosUI)
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("choose a screenshot", systemImage: "photo")
                    }
#endif
                    // Bound under another name: "remove" assigns to the state.
                    if let shown = previewImage {
                        HStack {
                            Image(decorative: shown, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Spacer()
                            Button("remove") {
                                imageData = nil
                                previewImage = nil
#if canImport(PhotosUI)
                                pickerItem = nil
#endif
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Picker("app", selection: $platform) {
                        ForEach(Self.platforms, id: \.key) { item in
                            Text(item.label).tag(item.key)
                        }
                    }
                    Picker("kind of post", selection: $style) {
                        ForEach(styles) { item in
                            Text(item.label).tag(item.key)
                        }
                    }
                    TextField("upvotes", text: $upvotes)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                        .onChange(of: upvotes) { _, newValue in
                            let digits = Self.digitsOnly(newValue)
                            if digits != newValue { upvotes = digits }
                        }
                    TextField("views", text: $views)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                        .onChange(of: views) { _, newValue in
                            let digits = Self.digitsOnly(newValue)
                            if digits != newValue { views = digits }
                        }
                    TextField("note", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .onChange(of: note) { _, newValue in
                            if newValue.count > 500 { note = String(newValue.prefix(500)) }
                        }
                    HStack {
                        Button {
                            send()
                        } label: {
                            Text("send")
                        }
                        .disabled(!canSend)
                        Spacer()
                        if isSending { ProgressView().controlSize(.small) }
                    }
                    if let error = model.lastError {
                        Text(error)
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.smoothTomatoInk)
                    }
                } header: {
                    SmoothSectionHeader("a post\u{2019}s result", accent: .smoothCobalt)
                }
                .smoothSectionBackground(.smoothMarigold)
            }
            .formStyle(.grouped)
            .font(.lhfSecondary(15))
            .foregroundStyle(Color.smoothInk)
            .smoothFormChrome(accent: .smoothMarigold)
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                        .disabled(isSending)
                }
            }
        }
        .lhfSheetTheme()
        .interactiveDismissDisabled(isSending)
        .onAppear {
            // The app the ambassador already said is theirs, unless the
            // server's style list does not hold the default kind.
            platform = model.anonApp.rawValue
            if !styles.contains(where: { $0.key == style }), let first = styles.first { style = first.key }
        }
#if canImport(PhotosUI)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                imageData = data
                previewImage = data.flatMap(PosterIdeaSheet.thumbnail)
            }
        }
#endif
#if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
#endif
    }

    /// `text` with everything but ASCII digits removed, at most nine of them
    /// (a count that large is a typo, and it keeps `Int` parsing safe).
    nonisolated static func digitsOnly(_ text: String) -> String {
        String(text.filter { $0 >= "0" && $0 <= "9" }.prefix(9))
    }

    private func send() {
        guard canSend, let data = imageData else { return }
        isSending = true
        let chosenPlatform = platform
        let chosenStyle = style
        let up = Int(upvotes)
        let seen = Int(views)
        let text = note
        Task {
            let ok = await model.sendPostResult(imageData: data, platform: chosenPlatform, style: chosenStyle,
                                                upvotes: up, views: seen, note: text)
            isSending = false
            if ok { dismiss() }
        }
    }
}

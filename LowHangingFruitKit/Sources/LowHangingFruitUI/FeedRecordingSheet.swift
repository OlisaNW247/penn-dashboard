import SwiftUI
import LowHangingFruitKit
import ImageIO
#if canImport(PhotosUI)
import PhotosUI
import UniformTypeIdentifiers
#endif

#if canImport(PhotosUI)
/// A screen recording picked from the photo library, copied to a temporary
/// file of our own. `PhotosPicker` hands over a file that lives only for the
/// duration of the import closure, so the copy is what outlives it; the sheet
/// deletes the copy as soon as the stills are cut. Loading it as `Data` would
/// hold the whole clip in memory, which for a two-minute recording is the
/// wrong trade.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("feed-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
#endif

/// "show us your feed": a screen recording of a scroll through the school's
/// anonymous app, sent as a handful of still pictures.
///
/// What leaves the phone, and only when the student taps "send": up to 16
/// stills, each a re-encoded JPEG with no metadata, never the video. Choosing
/// a recording sends nothing. The line under the strip tells the student to
/// look at the stills first, because a banner or a name can be on screen.
struct FeedRecordingSheet: View {
    @ObservedObject private var model = AmbassadorModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var stills: [Data] = []
    @State private var previews: [CGImage] = []
    @State private var isReading = false
    @State private var isSending = false
    @State private var sentDone = false
    @State private var readFailed = false
#if canImport(PhotosUI)
    @State private var pickerItem: PhotosPickerItem?
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("screen record a scroll through your school\u{2019}s feed.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("we\u{2019}ll write posts for you from what\u{2019}s working.")
                        .foregroundStyle(Color.v2DateText)
                        .fixedSize(horizontal: false, vertical: true)
#if canImport(PhotosUI)
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label("choose a recording", systemImage: "video")
                    }
                    .disabled(isReading || isSending)
#endif
                    if isReading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("reading the recording")
                                .foregroundStyle(Color.v2DateText)
                        }
                    }
                    if readFailed {
                        Text("couldn\u{2019}t read that recording")
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.smoothTomatoInk)
                    }
                    if !stills.isEmpty {
                        Text("\(stills.count) stills ready")
                            .font(.lhfSecondary(15, weight: .semibold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(previews.enumerated()), id: \.offset) { _, shown in
                                    Image(decorative: shown, scale: 1)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                        Text("we send stills, not the video. check nothing private is on screen.")
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.v2DateText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button {
                            send()
                        } label: {
                            Text(sentDone ? "sent" : sendLabel)
                        }
                        .disabled(stills.isEmpty || isSending || sentDone)
                        Spacer()
                        if isSending { ProgressView().controlSize(.small) }
                    }
                    if let error = model.lastError {
                        Text(error)
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.smoothTomatoInk)
                    }
                } header: {
                    SmoothSectionHeader("your feed", accent: .smoothCobalt)
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
#if canImport(PhotosUI)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            read(item)
        }
#endif
#if os(macOS)
        .frame(minWidth: 360, minHeight: 360)
#endif
    }

    /// "send", or "sent 3 of 12" while the stills are going up.
    private var sendLabel: String {
        if let progress = model.feedProgress { return "sent \(progress.sent) of \(progress.total)" }
        return "send"
    }

#if canImport(PhotosUI)
    private func read(_ item: PhotosPickerItem) {
        isReading = true
        readFailed = false
        stills = []
        previews = []
        Task {
            var cut: [Data] = []
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                // Off the main actor: `frames` is nonisolated and async.
                cut = await FeedRecordingFrames.frames(from: movie.url)
                try? FileManager.default.removeItem(at: movie.url)
            }
            stills = cut
            previews = cut.prefix(4).compactMap(PosterIdeaSheet.thumbnail)
            readFailed = cut.isEmpty
            isReading = false
        }
    }
#endif

    private func send() {
        guard !stills.isEmpty, !isSending else { return }
        isSending = true
        let batch = stills
        Task {
            let ok = await model.sendFeedFrames(batch)
            isSending = false
            if ok {
                sentDone = true
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            }
        }
    }
}

import SwiftUI
import LowHangingFruitKit
import ImageIO
#if canImport(PhotosUI)
import PhotosUI
#endif

/// "send a poster idea": a picture, a note, or both, to the founders.
///
/// What leaves the phone, and only when the student taps "send": the note (at
/// most 500 characters) and the picture, shrunk and re-encoded as a JPEG with
/// no location or other metadata (`PosterIdeaImage`), over the same ambassador
/// connection as everything else on the page. Choosing a picture sends
/// nothing; neither does typing.
///
/// `PhotosPicker` runs out of process, so the app needs no photo-library
/// permission. Package minimums are iOS 17 and macOS 14, where it exists, so
/// there is no availability branch; the `canImport` guard is only for a
/// platform without PhotosUI, which falls back to note-only.
///
/// The preview is decoded with ImageIO into a `CGImage` and drawn with
/// `Image(decorative:scale:)`, so there is no UIKit or AppKit branch. It is a
/// small thumbnail made for the preview alone; the original bytes are what
/// `sendPosterIdea` prepares.
struct PosterIdeaSheet: View {
    @ObservedObject private var model = AmbassadorModel.shared
    @Environment(\.dismiss) private var dismiss

    static let noteLimit = 500

    @State private var note = ""
    @State private var imageData: Data?
    @State private var previewImage: CGImage?
    @State private var isSending = false
#if canImport(PhotosUI)
    @State private var pickerItem: PhotosPickerItem?
#endif

    private var canSend: Bool {
        !isSending && (imageData != nil || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
#if canImport(PhotosUI)
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("choose a picture", systemImage: "photo")
                    }
#endif
                    if let previewImage {
                        HStack {
                            Image(decorative: previewImage, scale: 1)
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
                    TextField("what\u{2019}s the idea?", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: note) { _, newValue in
                            if newValue.count > Self.noteLimit { note = String(newValue.prefix(Self.noteLimit)) }
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
                    SmoothSectionHeader("poster idea", accent: .smoothCobalt)
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
            Task {
                // A picture that cannot be loaded is simply not chosen.
                let data = try? await item.loadTransferable(type: Data.self)
                imageData = data
                previewImage = data.flatMap(Self.thumbnail)
            }
        }
#endif
#if os(macOS)
        .frame(minWidth: 360, minHeight: 360)
#endif
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        let text = note
        let data = imageData
        Task {
            let ok = await model.sendPosterIdea(note: text, imageData: data)
            isSending = false
            if ok { dismiss() }
        }
    }

    /// A small preview of `data`, orientation applied, or nil if it is not an
    /// image. `nonisolated`: pure, callable from tests.
    nonisolated static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

import SwiftUI
import PDFKit

/// The rendered document, exactly as it will be submitted.
struct DraftPDFView {
    let data: Data

    static func pageCount(_ data: Data) -> Int { PDFDocument(data: data)?.pageCount ?? 0 }

    private func makeDocumentView() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }
}

#if os(iOS)
extension DraftPDFView: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { makeDocumentView() }
    func updateUIView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
    }
}
#else
extension DraftPDFView: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { makeDocumentView() }
    func updateNSView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
    }
}
#endif

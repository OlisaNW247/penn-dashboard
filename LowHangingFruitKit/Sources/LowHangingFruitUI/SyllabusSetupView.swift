import SwiftUI
import LowHangingFruitKit
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Attach a syllabus to a watched class, review what was read out of it, and
/// match its categories to Canvas's.
///
/// The whole flow is built around one rule: **nothing parsed is applied until
/// the user confirms it.** Every weight is shown next to the line it came
/// from, so the question being asked is "is this what your syllabus says?" —
/// something a student can answer in five seconds — rather than "do you trust
/// this app's reading of a PDF?", which nobody can answer.
struct SyllabusSetupView: View {
    @ObservedObject var store: GradeWatcherStore
    let courseID: String
    let courseName: String

    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case choosing
        case searching
        case reviewing(SyllabusCandidate, SyllabusGradingScheme)
        case failed(String)
        case matching
    }

    @State private var stage: Stage = .choosing
    @State private var pastedText = ""
    @State private var showPaste = false
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("syllabus")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("done") { dismiss() }
                    }
                }
                .lhfSheetTheme()
        }
        .onAppear {
            if store.syllabus(courseID: courseID) != nil { stage = .matching }
        }
#if canImport(UniformTypeIdentifiers)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .plainText]) { result in
            handleImportedFile(result)
        }
#endif
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .choosing:  chooser
        case .searching: searching
        case let .reviewing(candidate, scheme): review(candidate, scheme)
        case let .failed(message): failure(message)
        case .matching:  matching
        }
    }

    // MARK: - Choose a source

    private var chooser: some View {
        Form {
            Section {
                Text("lhf reads only the grading section. the category weights, any drop rules, how many assignments to expect, and the letter cutoffs if your syllabus lists them. it stays on your phone.")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
            }

            Section("find it automatically") {
                Button {
                    Task { await searchCanvas() }
                } label: {
                    Label("look on canvas", systemImage: "magnifyingglass")
                }
                .disabled(store.snapshots[courseID] == nil)
                Text("checks this course\u{2019}s syllabus page, its pages, and any file named like a syllabus.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
            }

            Section("or add it yourself") {
                Button {
                    showPaste = true
                } label: {
                    Label("paste the grading section", systemImage: "doc.on.clipboard")
                }
#if canImport(UniformTypeIdentifiers)
                Button {
                    showFileImporter = true
                } label: {
                    Label("choose a pdf", systemImage: "doc")
                }
#endif
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPaste) { pasteSheet }
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("paste the part of your syllabus that lists what each thing is worth.")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
                    .padding(.horizontal)
                TextEditor(text: $pastedText)
                    .font(.lhfSans(13))
                    .padding(6)
                    .background(Color.v2Card)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal)
                Spacer()
            }
            .padding(.top, 12)
            .background(Color.v2Bg)
            .navigationTitle("paste syllabus")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { showPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("read it") {
                        showPaste = false
                        parse(SyllabusCandidate(
                            id: "pasted",
                            source: .pasted,
                            name: "Pasted text",
                            text: SyllabusTextExtractor.text(fromPasted: pastedText)
                        ))
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                }
            }
        }
    }

    private var searching: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("looking for your syllabus on canvas\u{2026}")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2RingSub)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.v2Bg)
    }

    // MARK: - Review the parse

    private func review(_ candidate: SyllabusCandidate, _ scheme: SyllabusGradingScheme) -> some View {
        Form {
            Section {
                Text("found in \(candidate.name).")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
                if scheme.confidence == .medium {
                    Label(String(format: "These add up to %.0f%%, not 100%%. something may be missing. Check before using them.", scheme.rawWeightSum), systemImage: "exclamationmark.triangle")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2DueAmber)
                }
            } header: {
                Text("what we read")
            }

            Section("weights") {
                ForEach(scheme.normalizedCategories) { category in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(category.name)
                                .font(.lhfSans(13, weight: .medium))
                            Spacer()
                            Text(formatPercent(category.weightPercent))
                                .font(.lhfSans(13))
                                .foregroundStyle(Color.v2DateText)
                        }
                        if !category.evidence.isEmpty {
                            Text(category.evidence)
                                .font(.lhfSans(10))
                                .foregroundStyle(Color.v2RingSub)
                                .lineLimit(2)
                        }
                        if category.dropLowest > 0 || category.expectedItemCount != nil {
                            Text(extras(for: category))
                                .font(.lhfSans(10))
                                .foregroundStyle(Color.v2SpinePurple)
                        }
                    }
                }
            }

            if let cutoffs = scheme.cutoffs {
                Section("letter cutoffs") {
                    ForEach(cutoffs.bands) { band in
                        HStack {
                            Text(band.letter).font(.lhfSans(13, weight: .medium))
                            Spacer()
                            Text("\(formatPercent(band.minPercent)) and up")
                                .font(.lhfSans(12))
                                .foregroundStyle(Color.v2DateText)
                        }
                    }
                }
            }

            if scheme.mentionsCurve {
                Section {
                    Text("this syllabus mentions a curve or instructor discretion. lhf can\u{2019}t model that. treat the letter grades as approximate.")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2RingSub)
                }
            }

            Section {
                Button("use these weights") {
                    store.attachSyllabus(
                        AttachedSyllabus(scheme: scheme, source: candidate.source, documentName: candidate.name),
                        courseID: courseID
                    )
                    stage = .matching
                }
                Button("that\u{2019}s not right. start over", role: .destructive) {
                    stage = .choosing
                }
            }
        }
        .formStyle(.grouped)
    }

    private func extras(for category: SyllabusCategory) -> String {
        var parts: [String] = []
        if category.dropLowest > 0 {
            parts.append("drops \(category.dropLowest) lowest")
        }
        if let count = category.expectedItemCount {
            parts.append("\(count) expected")
        }
        return parts.joined(separator: " \u{00b7} ")
    }

    // MARK: - Match categories to Canvas

    @ViewBuilder
    private var matching: some View {
        if let match = store.syllabusMatch(courseID: courseID) {
            Form {
                Section {
                    if match.isCompleteCoverage {
                        Label("every category is matched. your syllabus\u{2019}s weights are in use.", systemImage: "checkmark.circle.fill")
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.v2SpineGreen)
                    } else {
                        Text("match each category from your syllabus to the matching canvas group. weights only take effect once every canvas group is covered. a half-matched syllabus would silently drop the rest of your grade.")
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.v2DateText)
                    }
                }

                Section("your syllabus \u{2192} canvas") {
                    ForEach(match.matches) { row in
                        matchRow(row)
                    }
                }

                if !match.unmatchedCanvasCategories.isEmpty {
                    Section("canvas groups with no syllabus weight") {
                        ForEach(match.unmatchedCanvasCategories) { category in
                            Text(category.name)
                                .font(.lhfSans(13))
                                .foregroundStyle(Color.v2DateText)
                        }
                    }
                }

                Section {
                    Button("remove this syllabus", role: .destructive) {
                        store.detachSyllabus(courseID: courseID)
                        stage = .choosing
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            Text("add a syllabus to match its categories.")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2RingSub)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.v2Bg)
        }
    }

    private func matchRow(_ row: SyllabusMatcher.Match) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.syllabusName)
                    .font(.lhfSans(13, weight: .medium))
                Spacer()
                Text(formatPercent(row.weightPercent))
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
            }

            Picker("canvas group", selection: Binding(
                get: { row.canvasCategoryID ?? "" },
                set: { newValue in
                    if newValue.isEmpty {
                        store.clearCategoryMapping(courseID: courseID, syllabusCategoryID: row.syllabusCategoryID)
                    } else {
                        store.confirmCategoryMapping(
                            courseID: courseID,
                            syllabusCategoryID: row.syllabusCategoryID,
                            canvasCategoryID: newValue
                        )
                    }
                }
            )) {
                Text("not matched").tag("")
                ForEach(store.gradeCategories(courseID: courseID)) { category in
                    Text(category.name).tag(category.id)
                }
            }
            .font(.lhfSans(12))

            switch row.tier {
            case .exact:
                Text("names match").font(.lhfSans(10)).foregroundStyle(Color.v2SpineGreen)
            case .confirmed:
                Text("you matched this").font(.lhfSans(10)).foregroundStyle(Color.v2SpineGreen)
            case .fuzzy:
                Text("suggested. confirm it above to use it")
                    .font(.lhfSans(10))
                    .foregroundStyle(Color.v2DueAmber)
            case .unmatched:
                Text("pick the canvas group this covers")
                    .font(.lhfSans(10))
                    .foregroundStyle(Color.v2RingSub)
            }
        }
    }

    // MARK: - Failure

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.lhfSans(13))
                .foregroundStyle(Color.v2Ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("you can still set weights by hand on the report. tap any category\u{2019}s weight to edit it.")
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2RingSub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("try another source") { stage = .choosing }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.v2Bg)
    }

    // MARK: - Work

    private func searchCanvas() async {
        stage = .searching
        let cookies = await AutoSyncCoordinator.canvasCookies()
        guard !cookies.isEmpty else {
            stage = .failed("Grades need a live Canvas login to read your syllabus. Reconnect Canvas, then try again.")
            return
        }

        let client = CanvasSyllabusClient(cookies: cookies)
        do {
            let candidates = try await client.findCandidates(courseID: courseID)
            // First candidate that actually yields a scheme wins — a course
            // often has both an empty syllabus page and the real PDF.
            for candidate in candidates {
                if let scheme = SyllabusParser.parse(candidate.text) {
                    stage = .reviewing(candidate, scheme)
                    return
                }
            }
            stage = .failed(candidates.isEmpty
                ? "Couldn\u{2019}t find a syllabus on Canvas for this class."
                : "Found a syllabus, but couldn\u{2019}t read a grading table out of it.")
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func parse(_ candidate: SyllabusCandidate) {
        guard let scheme = SyllabusParser.parse(candidate.text) else {
            stage = .failed("Couldn\u{2019}t find a grading breakdown in that text. It needs the lines that say what each part is worth. and they should add up to about 100%.")
            return
        }
        stage = .reviewing(candidate, scheme)
    }

#if canImport(UniformTypeIdentifiers)
    private func handleImportedFile(_ result: Result<URL, Swift.Error>) {
        guard case let .success(url) = result else { return }
        // Files picked outside the app's container are security-scoped.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            stage = .failed("Couldn\u{2019}t open that file.")
            return
        }

        let text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = SyllabusTextExtractor.text(fromPDF: data)
        } else {
            text = String(data: data, encoding: .utf8).map(SyllabusTextExtractor.text(fromPasted:))
        }

        guard let text, !text.isEmpty else {
            stage = .failed("Couldn\u{2019}t read any text out of that file. If it\u{2019}s a scan, paste the grading section instead.")
            return
        }
        parse(SyllabusCandidate(
            id: url.lastPathComponent,
            source: .importedFile,
            name: url.lastPathComponent,
            text: text
        ))
    }
#endif
}

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
                .navigationTitle("Syllabus")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
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
                Text("LHF reads only the grading section \u{2014} the category weights, any drop rules, how many assignments to expect, and the letter cutoffs if your syllabus lists them. It stays on your phone.")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
            }

            Section("Find it automatically") {
                Button {
                    Task { await searchCanvas() }
                } label: {
                    Label("Look on Canvas", systemImage: "magnifyingglass")
                }
                .disabled(store.snapshots[courseID] == nil)
                Text("Checks this course\u{2019}s syllabus page, its pages, and any file named like a syllabus.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
            }

            Section("Or add it yourself") {
                Button {
                    showPaste = true
                } label: {
                    Label("Paste the grading section", systemImage: "doc.on.clipboard")
                }
#if canImport(UniformTypeIdentifiers)
                Button {
                    showFileImporter = true
                } label: {
                    Label("Choose a PDF", systemImage: "doc")
                }
#endif
            }
        }
        .sheet(isPresented: $showPaste) { pasteSheet }
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste the part of your syllabus that lists what each thing is worth.")
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
            .navigationTitle("Paste syllabus")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Read it") {
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
            Text("Looking for your syllabus on Canvas\u{2026}")
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
                Text("Found in \(candidate.name).")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
                if scheme.confidence == .medium {
                    Label(String(format: "These add up to %.0f%%, not 100%% \u{2014} something may be missing. Check before using them.", scheme.rawWeightSum), systemImage: "exclamationmark.triangle")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2DueAmber)
                }
            } header: {
                Text("What we read")
            }

            Section("Weights") {
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
                Section("Letter cutoffs") {
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
                    Text("This syllabus mentions a curve or instructor discretion. LHF can\u{2019}t model that \u{2014} treat the letter grades as approximate.")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2RingSub)
                }
            }

            Section {
                Button("Use these weights") {
                    store.attachSyllabus(
                        AttachedSyllabus(scheme: scheme, source: candidate.source, documentName: candidate.name),
                        courseID: courseID
                    )
                    stage = .matching
                }
                Button("That\u{2019}s not right \u{2014} start over", role: .destructive) {
                    stage = .choosing
                }
            }
        }
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
                        Label("Every category is matched \u{2014} your syllabus\u{2019}s weights are in use.", systemImage: "checkmark.circle.fill")
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.v2SpineGreen)
                    } else {
                        Text("Match each category from your syllabus to the matching Canvas group. Weights only take effect once every Canvas group is covered \u{2014} a half-matched syllabus would silently drop the rest of your grade.")
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.v2DateText)
                    }
                }

                Section("Your syllabus \u{2192} Canvas") {
                    ForEach(match.matches) { row in
                        matchRow(row)
                    }
                }

                if !match.unmatchedCanvasCategories.isEmpty {
                    Section("Canvas groups with no syllabus weight") {
                        ForEach(match.unmatchedCanvasCategories) { category in
                            Text(category.name)
                                .font(.lhfSans(13))
                                .foregroundStyle(Color.v2DateText)
                        }
                    }
                }

                Section {
                    Button("Remove this syllabus", role: .destructive) {
                        store.detachSyllabus(courseID: courseID)
                        stage = .choosing
                    }
                }
            }
        } else {
            Text("Add a syllabus to match its categories.")
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

            Picker("Canvas group", selection: Binding(
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
                Text("Not matched").tag("")
                ForEach(store.gradeCategories(courseID: courseID)) { category in
                    Text(category.name).tag(category.id)
                }
            }
            .font(.lhfSans(12))

            switch row.tier {
            case .exact:
                Text("Names match").font(.lhfSans(10)).foregroundStyle(Color.v2SpineGreen)
            case .confirmed:
                Text("You matched this").font(.lhfSans(10)).foregroundStyle(Color.v2SpineGreen)
            case .fuzzy:
                Text("Suggested \u{2014} confirm it above to use it")
                    .font(.lhfSans(10))
                    .foregroundStyle(Color.v2DueAmber)
            case .unmatched:
                Text("Pick the Canvas group this covers")
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
            Text("You can still set weights by hand on the report \u{2014} tap any category\u{2019}s weight to edit it.")
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2RingSub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try another source") { stage = .choosing }
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
            stage = .failed("Couldn\u{2019}t find a grading breakdown in that text. It needs the lines that say what each part is worth \u{2014} and they should add up to about 100%.")
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

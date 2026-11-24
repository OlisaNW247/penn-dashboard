import SwiftUI
import LowHangingFruitKit

/// "add an ambassador": the sheet an allowed ambassador (a founder) uses to
/// make a code for a new person at any school, with no app update. The server
/// decides who may and says so in the plan; this view is only reached from a
/// row that exists when it did.
///
/// What leaves the phone, on "make code" only: the new person's name, their
/// school (an existing one's id, or a new one's name with its Canvas host when
/// it came from the app's own school list) and a phone number if one was
/// typed. The new code comes back once and is shown here; it is held in this
/// view's state alone, never written to defaults or the Keychain, and is gone
/// when the sheet closes.
struct AmbassadorInviteSheet: View {
    @ObservedObject private var model = AmbassadorModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var personName = ""
    @State private var schoolQuery = ""
    @State private var chosenSchool: AmbassadorSchoolSearch.Match?
    /// The name a NEW school is created under: the label every screen then
    /// shows ("12 users at harvard so far") and the front of that school's
    /// codes (`harvard-...`). Prefilled from the catalog's short name and the
    /// founder's to edit, because two universities can share one ("USC") and
    /// only a person knows which word their campus actually uses. Unused for
    /// a school the site already has, which keeps its own name.
    @State private var shortName = ""
    @State private var phone = ""
    @State private var created: AmbassadorInviteResult?
    @State private var createdFor = ""

    private var existingSchools: [AmbassadorPlan.Invite.School] {
        model.plan?.invite?.schools ?? []
    }

    private var typedSchool: String {
        schoolQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestions: [AmbassadorSchoolSearch.Match] {
        AmbassadorSchoolSearch.matches(query: typedSchool, existing: existingSchools)
    }

    private var canMake: Bool {
        !model.isWorking
            && !personName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chosenSchool != nil
            && (chosenSchool?.existingID != nil
                || shortName.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let made = created {
                    madeSections(made)
                } else {
                    formSections
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                        .disabled(model.isWorking)
                }
            }
        }
        .lhfSheetTheme()
        .interactiveDismissDisabled(model.isWorking)
        .onAppear { model.clearError() }
#if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
#endif
    }

    // MARK: Before

    @ViewBuilder
    private var formSections: some View {
        Section {
            TextField("name", text: $personName)
                .autocorrectionDisabled()
#if os(iOS)
                .textContentType(.name)
#endif
            if let picked = chosenSchool {
                HStack {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.smoothTealInk)
                    Text(picked.name)
                    Spacer()
                    Button("change") {
                        chosenSchool = nil
                        shortName = ""
                    }
                    .buttonStyle(.borderless)
                }
                if picked.existingID == nil {
                    TextField("short name", text: $shortName)
                        .autocorrectionDisabled()
                }
            } else {
                TextField("school", text: $schoolQuery)
                    .autocorrectionDisabled()
                ForEach(suggestions, id: \.name) { match in
                    Button {
                        chosenSchool = match
                        shortName = match.shortName
                    } label: {
                        HStack {
                            Text(match.name)
                            Spacer()
                            if match.existingID != nil {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(Color.v2DateText)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if typedSchool.count >= 2 {
                    Button {
                        chosenSchool = AmbassadorSchoolSearch.Match(
                            name: typedSchool, shortName: typedSchool, existingID: nil, host: nil)
                        shortName = typedSchool
                    } label: {
                        Text("use \u{201C}\(typedSchool)\u{201D}")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("phone (optional)", text: $phone)
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.phonePad)
#endif
            HStack {
                Button {
                    make()
                } label: {
                    Text("make code")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.smoothGrape)
                .disabled(!canMake)
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            if let error = model.lastError {
                Text(error)
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.smoothTomatoInk)
            }
        } header: {
            SmoothSectionHeader("add an ambassador", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothGrape)
    }

    // MARK: After

    @ViewBuilder
    private func madeSections(_ made: AmbassadorInviteResult) -> some View {
        Section {
            Text(createdFor.lowercased())
                .font(.lhfSecondary(17))
            Text((made.schoolName ?? chosenSchool?.name ?? "").lowercased())
                .foregroundStyle(Color.v2DateText)
            AmbassadorPostBox(text: made.code)
            AmbassadorCopyButton(label: "copy code", text: made.code)
            if let welcome = made.welcome, !welcome.isEmpty {
                AmbassadorCopyButton(label: "copy welcome text", text: welcome)
                ShareLink(item: welcome) {
                    Label("share", systemImage: "square.and.arrow.up")
                }
            } else {
                ShareLink(item: made.code) {
                    Label("share", systemImage: "square.and.arrow.up")
                }
            }
            HStack {
                Button("add another") { reset() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.smoothGrape)
            }
        } header: {
            SmoothSectionHeader("code", accent: .smoothCobalt)
        }
        .smoothSectionBackground(.smoothTeal)
    }

    // MARK: Actions

    private func make() {
        guard canMake, let picked = chosenSchool else { return }
        let nameToSend = personName
        let contactToSend = phone
        let newSchoolName = shortName
        Task {
            let result = await model.invite(
                name: nameToSend,
                schoolID: picked.existingID,
                schoolName: picked.existingID == nil ? newSchoolName : nil,
                schoolHost: picked.existingID == nil ? picked.host : nil,
                contact: contactToSend)
            if let result {
                createdFor = nameToSend.trimmingCharacters(in: .whitespacesAndNewlines)
                created = result
            }
        }
    }

    private func reset() {
        personName = ""
        schoolQuery = ""
        chosenSchool = nil
        shortName = ""
        phone = ""
        created = nil
        createdFor = ""
        model.clearError()
    }
}

import SwiftUI
import LowHangingFruitKit

struct SchoolSelectionView: View {
    let onSelect: (CanvasInstallation) -> Void
    @State private var query = ""
    @State private var showAddress = false
    @State private var address = ""
    @State private var addressError: String?

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleResults: [CanvasInstallation] {
        CanvasSchoolDirectory.bundledMatches(for: term)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find your school")
                        .font(.lhfSerif(34))
                        .foregroundStyle(Color.v2Ink)
                    Text("Search your university to sign in to Canvas.")
                        .font(.body)
                        .foregroundStyle(Color.v2DateText)
                }
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField("University name", text: $query)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .font(.body)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 15))

                if !term.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleResults) { school in
                            Button { onSelect(school) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(school.name).font(.headline).foregroundStyle(Color.v2Ink)
                                        Text(school.host).font(.caption).foregroundStyle(Color.v2DateText)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").accessibilityHidden(true)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 15))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens this school's Canvas sign-in")
                        }
                        if term.count < 2 {
                            Text("Type at least two letters.")
                        } else if visibleResults.isEmpty {
                            Text("No schools found. Try the full name or enter your Canvas address below.")
                        } else if visibleResults.count >= 100 {
                            Text("Lots of matches — add your campus or more of the school name.")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.v2DateText)
                }

                DisclosureGroup("Can’t find your school?", isExpanded: $showAddress) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("If your school uses Canvas, paste its Canvas website address.")
                            .font(.subheadline)
                        TextField("canvas.school.edu", text: $address)
                            .textFieldStyle(.plain)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .autocorrectionDisabled()
                            .padding(16)
                            .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 15))
                        if let addressError {
                            Text(addressError).font(.caption).foregroundStyle(Color.smoothTomatoInk)
                        }
                        Button("Continue with Canvas address") {
                            guard let school = CanvasInstallation.custom(address: address) else {
                                addressError = "Enter a public HTTPS Canvas address, such as canvas.school.edu."
                                return
                            }
                            addressError = nil
                            onSelect(school)
                        }
                        .frame(minHeight: 44)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.top, 12)
                }
                .font(.subheadline)
                .tint(Color.v2Ink)
                Text("Search major US universities, or enter your Canvas address.")
                    .font(.caption)
                    .foregroundStyle(Color.v2DateText)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.v2Bg.ignoresSafeArea())
    }
}

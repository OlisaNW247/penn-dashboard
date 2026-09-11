import SwiftUI
import LowHangingFruitKit

/// Lets a student correct one Canvas grade item -- a wrong score Canvas
/// hasn't fixed yet, or a line that shouldn't count at all ("professor said
/// this one's dropped," "extra credit I skipped"). The correction is a
/// `GradeItemOverride` layered on top of Canvas's own numbers
/// (`GradeItemOverride`'s doc comment explains why: it's the STUDENT's
/// call, applied first, before the rest of the engine runs) -- nothing here
/// ever writes to Canvas, and "reset to canvas" always gets back to exactly
/// what Canvas said with no residue.
struct GradeItemEditorSheet: View {
    @ObservedObject var store: GradeWatcherStore
    let courseID: String
    let item: GradeItem
    let currentOverride: GradeItemOverride?

    @Environment(\.dismiss) private var dismiss

    @State private var scoreText: String
    @State private var pointsPossibleText: String
    @State private var isExcluded: Bool

    init(store: GradeWatcherStore, courseID: String, item: GradeItem, currentOverride: GradeItemOverride?) {
        self.store = store
        self.courseID = courseID
        self.item = item
        self.currentOverride = currentOverride
        _scoreText = State(initialValue: currentOverride?.score.map(formatPoints) ?? "")
        _pointsPossibleText = State(initialValue: currentOverride?.pointsPossible.map(formatPoints) ?? "")
        _isExcluded = State(initialValue: currentOverride?.isExcluded ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("score")
                        Spacer()
                        TextField(scorePlaceholder, text: $scoreText)
#if os(iOS)
                            .keyboardType(.decimalPad)
#endif
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("score for \(item.name)")
                    }
                    HStack {
                        Text("points possible")
                        Spacer()
                        TextField(pointsPossiblePlaceholder, text: $pointsPossibleText)
#if os(iOS)
                            .keyboardType(.decimalPad)
#endif
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("points possible for \(item.name)")
                    }
                    Toggle("doesn\u{2019}t count", isOn: $isExcluded)
                }

                Section {
                    Text("canvas: \(canvasReferenceText)")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2RingSub)
                    Text("edits stay on this phone and never change canvas.")
                        .font(.lhfSans(10.5))
                        .foregroundStyle(Color.v2RingSub)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if currentOverride != nil {
                    Section {
                        Button("reset to canvas", role: .destructive) {
                            store.setItemOverride(courseID: courseID, itemID: item.id, override: nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(item.name)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") { save() }
                }
            }
        }
    }

    private var scorePlaceholder: String {
        item.score.map(formatPoints) ?? "not graded"
    }

    private var pointsPossiblePlaceholder: String {
        formatPoints(item.pointsPossible)
    }

    private var canvasReferenceText: String {
        "\(item.score.map(formatPoints) ?? "\u{2014}") / \(formatPoints(item.pointsPossible))"
    }

    /// Only writes the fields the student actually changed -- an untouched
    /// text field means "keep canvas's number," not "set it to zero," so a
    /// blank score/points field maps to `nil` in the override rather than 0.
    /// `GradeItemOverride.isEmpty` collapses a no-op edit (every field left
    /// blank, toggle left off) to `nil` so opening the sheet and saving
    /// without changing anything doesn't leave a phantom override behind.
    private func save() {
        let score = Double(scoreText)
        let pointsPossible = Double(pointsPossibleText)
        let override = GradeItemOverride(score: score, pointsPossible: pointsPossible, isExcluded: isExcluded)
        store.setItemOverride(courseID: courseID, itemID: item.id, override: override.isEmpty ? nil : override)
        dismiss()
    }
}

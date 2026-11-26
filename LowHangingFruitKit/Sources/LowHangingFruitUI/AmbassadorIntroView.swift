import SwiftUI
import LowHangingFruitKit

/// The sheet an ambassador sees after every sign-in (`AmbassadorModel.introPending`, written by `signIn`, cleared by
/// `finishIntro`, remembered under `introSeenKey`). Marco, 2026-11-21: the job
/// in one line and the four tasks, nothing else. The four rows use the same
/// symbols the page's task rows do, so the intro is a preview of the page.
struct AmbassadorIntroView: View {
    @ObservedObject private var model = AmbassadorModel.shared

    private var rows: [(String, String)] {
        [
            (AmbassadorTask.feedback.symbol, "download the app and tell us what\u{2019}s wrong"),
            (AmbassadorTask.anonChats.symbol, "post in your anonymous chats"),
            (AmbassadorTask.groupChats.symbol, "drop it in your group chats"),
            (AmbassadorTask.posters.symbol, "put up posters"),
        ]
    }

    private var goalLine: String {
        let target = AmbassadorGoals.downloadsTarget
        guard let label = model.plan?.schoolLabel, !label.isEmpty else { return "goal: \(target) downloads" }
        return "goal: \(target) downloads at \(label)"
    }

    var body: some View {
        Form {
            Section {
                SmoothFormHeader(title: "Ambassador", accent: .smoothGrape, spark: .smoothMarigold)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .listRowSeparator(.hidden)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("thanks for being one.")
                        .font(.lhfSecondary(17, weight: .semibold))
                    Text("your job: get smooth in front of as many eyes as you can.")
                        .font(.lhfSecondary(15))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                ForEach(rows, id: \.1) { symbol, text in
                    HStack(spacing: 10) {
                        Image(systemName: symbol)
                            .frame(width: 22)
                        Text(text)
                            .font(.lhfSecondary(15))
                    }
                }
                Text(goalLine)
                    .font(.lhfSecondary(15, weight: .semibold))
                Text("you\u{2019}re smooth at your school. bring back what people say.")
                    .font(.lhfSecondary(14))
                    .foregroundStyle(Color.v2DateText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.finishIntro()
                } label: {
                    Text("let\u{2019}s go")
                        .font(.lhfSecondary(15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.smoothGrape)
                .listRowSeparator(.hidden)
            }
            .smoothSectionBackground(.smoothLemon)
        }
        .formStyle(.grouped)
        .font(.lhfSecondary(15))
        .foregroundStyle(Color.smoothInk)
        .smoothFormChrome(accent: .smoothGrape)
        .lhfSheetTheme()
        .frame(minWidth: 360, minHeight: 420)
    }
}

import SwiftUI

struct SegmentedToggleView<Option: Hashable & CustomStringConvertible>: View {
    let options: [Option]
    @Binding var selection: Option
    var counts: [Option: Int] = [:]

    @Namespace private var capsule

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        selection = option
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(option.description)
                            .font(.geist(13, weight: selection == option ? .semibold : .regular))
                        if let count = counts[option], count > 0 {
                            Text("\(count)")
                                .font(.geist(11, weight: .medium))
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    selection == option
                                        ? Color.lhfGraphite.opacity(0.18)
                                        : Color.lhfGraphite.opacity(0.08),
                                    in: Capsule()
                                )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        if selection == option {
                            Capsule()
                                .fill(Color.lhfGraphite)
                                .matchedGeometryEffect(id: "pill", in: capsule)
                        }
                    }
                    .foregroundStyle(selection == option ? Color.lhfEggshell : Color.lhfGraphite.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.lhfGraphite.opacity(0.08), in: Capsule())
    }
}

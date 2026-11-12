import SwiftUI
import LowHangingFruitKit

/// Every poster design the ambassador's school has, in the server's order, so
/// they can see what is on the walls and share or save one to print. Opened
/// from Profile → ambassador → "all posters" as a sheet with a stack of its
/// own: tapping a poster pushes a large view inside the sheet, so "back" and
/// "close" mean what they say.
///
/// Token colours only (no literal colours), so dark mode needs nothing extra.
/// The pictures are the server's own https URLs, loaded by `AsyncImage`; a
/// poster whose URL is not https shows the placeholder and nothing else
/// (`Poster.imageURL` is nil). Nothing is stored on the phone, and nothing
/// leaves it: loading a picture is an ordinary GET of a public file.
struct AmbassadorPostersView: View {
    let posters: [AmbassadorPlan.Poster]
    let schoolLabel: String

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(posters) { poster in
                        NavigationLink {
                            AmbassadorPosterDetail(poster: poster)
                        } label: {
                            card(poster)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Color.smoothSurface.opacity(0.35))
            .foregroundStyle(Color.smoothInk)
            .navigationTitle("posters \u{00B7} \(schoolLabel)")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                }
            }
        }
        .lhfSheetTheme()
#if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
#endif
    }

    private func card(_ poster: AmbassadorPlan.Poster) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AmbassadorPosterPicture(url: poster.imageURL)
            Text(poster.name)
                .font(.lhfSecondary(14, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let scans = poster.scans {
                Text("\(scans) scans")
                    .font(.lhfMono(12, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A poster picture with a rounded `smoothSurface` placeholder while it loads
/// or when it cannot.
private struct AmbassadorPosterPicture: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
            default:
                Color.smoothSurface
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One poster, large, with the one thing to do with it.
private struct AmbassadorPosterDetail: View {
    let poster: AmbassadorPlan.Poster

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                AmbassadorPosterPicture(url: poster.imageURL)
                if let scans = poster.scans {
                    Text("\(scans) scans")
                        .font(.lhfMono(13, weight: .medium))
                        .foregroundStyle(Color.v2DateText)
                }
                if let url = poster.imageURL {
                    ShareLink(item: url) {
                        Label("share or save", systemImage: "square.and.arrow.up")
                            .font(.lhfSecondary(15, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.smoothGrape)
                }
            }
            .padding(16)
        }
        .foregroundStyle(Color.smoothInk)
        .navigationTitle(poster.name)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

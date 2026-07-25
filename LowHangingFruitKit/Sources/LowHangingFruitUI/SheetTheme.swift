import SwiftUI

/// Keeps a sheet in the app's own palette instead of the default system form
/// look: the v2 canvas behind the rows (which now adapts light/dark via the
/// tokens) and the v2 blue as the control tint instead of system blue. The
/// sheet follows the system appearance like the rest of the app — the tokens
/// carry light/dark, so no scheme is forced here anymore.
private struct LHFSheetTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(Color.v2SpineBlue)
            .scrollContentBackground(.hidden)
            .background(Color.v2Bg)
    }
}

extension View {
    func lhfSheetTheme() -> some View { modifier(LHFSheetTheme()) }
}

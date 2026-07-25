import SwiftUI

/// A plain SwiftUI sheet follows the *device* appearance by default, not the
/// app's own Light/Dark setting — so without this, a pop-up could render as a
/// black system form floating over a light-mode app (or vice versa) whenever
/// the two disagree. Applying this to a sheet's root keeps the presentation
/// in the app's own world: the app's chosen color scheme, the v2 field color
/// behind rows, and the v2 blue as the control tint instead of system blue.
///
/// Each sheet needs its own application — `preferredColorScheme` only reaches
/// the nearest enclosing presentation, so a parent sheet's theme does not
/// cover a sheet presented from inside it.
private struct LHFSheetTheme: ViewModifier {
    @EnvironmentObject private var state: AppState

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(state.appearanceMode.colorScheme)
            .tint(Color.v2SpineBlue)
            .scrollContentBackground(.hidden)
            .background(Color.v2Bg)
    }
}

extension View {
    func lhfSheetTheme() -> some View { modifier(LHFSheetTheme()) }
}

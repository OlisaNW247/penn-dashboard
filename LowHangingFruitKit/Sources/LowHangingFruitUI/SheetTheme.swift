import SwiftUI

/// LHF ships light-only: the dashboard hardcodes the v2 paper palette, but a
/// plain SwiftUI sheet follows the device appearance — so with the phone in
/// dark mode every pop-up rendered as a black system form floating over the
/// cream app. Applying this to a sheet's root keeps the presentation in the
/// app's world: light scheme, the greige field behind white rows, and the v2
/// blue as the control tint instead of system blue.
///
/// Each sheet needs its own application — `preferredColorScheme` only reaches
/// the nearest enclosing presentation, so a parent sheet's theme does not
/// cover a sheet presented from inside it.
private struct LHFSheetTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(.light)
            .tint(Color.v2SpineBlue)
            .scrollContentBackground(.hidden)
            .background(Color.v2Bg)
    }
}

extension View {
    func lhfSheetTheme() -> some View { modifier(LHFSheetTheme()) }
}

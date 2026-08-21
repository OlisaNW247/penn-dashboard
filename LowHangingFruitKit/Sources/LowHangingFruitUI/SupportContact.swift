import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The single place the "report a problem" support destination is
/// configured. This is a dedicated support alias, not a personal address —
/// a mail compose sheet always shows the recipient to the person sending it,
/// so there's no way to route reports somewhere hidden even if we wanted to.
/// This same address is also what's listed as the App Store "Support"
/// contact, so it needs to be an inbox someone actually reads.
enum SupportContact {
    /// Where "Report a problem" sends reports.
    // TODO: set this to a real, monitored support alias before shipping.
    static let reportAddress = "REPLACE_ME@example.com"
    static let reportSubject = "LHF — Canvas login problem"

    /// Builds a `mailto:` link to `reportAddress` with `reportSubject` and a
    /// body that opens with a short prompt followed by the diagnostics
    /// report, then opens it with the platform's mail handler. Does nothing
    /// if the URL can't be built (e.g. percent-encoding somehow fails).
    static func openReportMail(diagnostics: String) {
        let body = "Describe what happened above this line:\n\n\n---\n\(diagnostics)"
        guard let subjectEncoded = reportSubject.addingPercentEncoding(withAllowedCharacters: .lhfURLQueryValue),
              let bodyEncoded = body.addingPercentEncoding(withAllowedCharacters: .lhfURLQueryValue) else {
            return
        }
        guard let url = URL(string: "mailto:\(reportAddress)?subject=\(subjectEncoded)&body=\(bodyEncoded)") else {
            return
        }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

private extension CharacterSet {
    /// Characters safe to leave unescaped within a single `mailto:` query
    /// value (a `subject=` or `body=` component). `.urlQueryAllowed` isn't
    /// strict enough here — it still permits `&`, `=`, `?`, and `+`, all of
    /// which would corrupt or get reinterpreted inside a query value, and it
    /// leaves whitespace unescaped too. This starts from alphanumerics and
    /// adds back only a small set of punctuation that's unambiguously safe
    /// inside a query value; everything else (including `%` and `#`, which
    /// also have special meaning in URLs) gets percent-encoded.
    static let lhfURLQueryValue: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~,;:!'")
        return set
    }()
}

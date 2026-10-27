import Foundation
import SwiftUI

/// Which links in an ask answer may be opened.
///
/// The answer is the model's text, and the model is handed material it did not
/// write: pooled announcements, pages and Ed posts that any classmate's phone
/// or laptop uploaded, plus whatever the student typed. `AssistantView` parses
/// the finished answer as inline Markdown, so a `[label](url)` or `<url>` in
/// it becomes a tappable link, and SwiftUI hands every tap to the system for
/// any scheme: `https` to a look-alike login page, `tel:`, `mailto:`, a
/// `smooth://` link, another app's URL scheme. A prompt-injected sentence in a
/// pooled post ("the full answer is at [the syllabus](https://...)") is the
/// realistic path to that. Nothing in an answer needs to leave the app for a
/// place the student's own classes do not live, so the rule is a short
/// allow-list rather than a search for bad links.
///
/// **The rule.** `https`, and a host that is exactly the student's Canvas host
/// or one of Ed Discussion's two (`edstem.org`, `us.edstem.org`), compared
/// case-insensitively. Exact, not a suffix: `canvas.upenn.edu.example.com`,
/// `notedstem.org` and `https://canvas.upenn.edu@example.com/` (whose host is
/// `example.com`) all fail, and a relative or schemeless URL has no host and
/// fails too. `http` fails even on an allowed host, since Canvas and Ed only
/// ever serve `https` and a plain link there is a downgrade, not a shortcut.
/// With no known Canvas host (a preview, a test) only Ed passes.
///
/// A link that fails is dropped without a word: the text it labelled stays
/// readable, tapping it does nothing, and no new copy appears on screen.
///
/// **What this does not cover, on purpose.** The source chips under an answer
/// are not model-written: their URL comes from the excerpt document the phone
/// itself sent (`CitationLinks.resolve`, which already refuses anything but
/// `https` with a host), and the server cannot return one. They include course
/// websites, which live on hosts this list does not know, so gating them here
/// would turn a working chip into a dead one. The environment action is
/// therefore installed on the answer text only, and the chips keep the system
/// default. How far to trust a pooled document's URL is the backend's call
/// (`BackendWire`, plan item BE-D), not this screen's.
///
/// The wrong fix is to strip links when the Markdown is parsed: it also
/// removes a link to the student's own Canvas page or Ed thread, which is the
/// one kind worth keeping, and a model that writes one anyway leaves label
/// text that no longer does what it looks like it does.
enum AnswerLinkPolicy {
    /// Ed Discussion's hosts: a thread's own link opens on `edstem.org`
    /// (`EdIngestion`) and its API answers from `us.edstem.org` (`EdClient`).
    static let edHosts: Set<String> = ["edstem.org", "us.edstem.org"]

    /// Whether `url` may be opened from an answer. Pure, so the rule is tested
    /// without a view.
    static func allows(_ url: URL, canvasHost: String?) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty
        else { return false }
        if edHosts.contains(host) { return true }
        guard let canvas = canvasHost?.lowercased(), !canvas.isEmpty else { return false }
        return host == canvas
    }

    /// The action `AssistantView` installs on the answer text.
    static func openURLAction(canvasHost: String?) -> OpenURLAction {
        OpenURLAction { url in
            allows(url, canvasHost: canvasHost) ? .systemAction : .discarded
        }
    }
}

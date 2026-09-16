import Foundation

/// Pure, network-free helpers for the "stay signed in" auto-login feature —
/// the owner's decision (CLAUDE.md's "stay signed in" entry) to optionally
/// store a student's PennKey username/password and use them to fill and
/// submit Penn's own Shibboleth login form from inside the app's isolated
/// login `WKWebView`, so a dead Canvas session can be recovered without the
/// student re-typing their password every time.
///
/// **This is deliberately narrow, and deliberately NOT the thing
/// docs/CANVAS_LOGIN_HARDENING.md's post-mortem forbids.** That document's
/// bug was Shibboleth's login conversation being consumed by a SECOND POST
/// of the SAME credential submission — a double-submitted `j_username`/
/// `j_password` form — which the IdP then rejected as a stale replay for
/// every subsequent attempt in the process. The fix living in
/// `LoginNavigationObserver` (the duplicate-POST guard) and the separate
/// app-link guard both exist to keep that specific failure from recurring on
/// the SAML *response* form Canvas auto-submits on the way back from the
/// IdP. Nothing here goes near that form or that hop: `PennKeyLoginForm`
/// only ever recognizes and fills the IdP's *credential* form
/// (`j_username`/`j_password`, `#loginform`) and only ever submits it once
/// per script invocation, gated by its own `window.__lhfAutoLogin` sentinel
/// (see `fillAndSubmitScript`). The callers that invoke this script
/// (`LoginNavigationObserver`, `CanvasSessionRenewer`) are each responsible
/// for calling it at most once per page load / per attempt — see their own
/// doc comments for how they enforce that on their side.
///
/// Rejected alternatives, recorded here because they looked obviously
/// simpler and are not what shipped:
/// - **Scraping the password out of the login page's DOM** once the student
///   types it in by hand: rejected outright. That is keylogging the
///   student's own PennKey password inside a screen the app's privacy
///   posture (docs/PRIVACY.md) promises never sees what they type — the only
///   password this feature ever touches is the one the student explicitly
///   typed into Smooth's own Settings sheet and asked to be remembered.
/// - **Retrying a rejected password:** rejected. PennKey/Duo accounts lock
///   after a small number of consecutive failures, and a background loop
///   that could hammer a wrong password against Penn's IdP is precisely the
///   thing that would lock a student out of everything at Penn, not just
///   Smooth. Every caller of this type disables itself after one rejected
///   attempt and requires the student to re-enter the password by hand.
public enum PennKeyLoginForm {
    /// Hosts Penn's Shibboleth IdP has been observed serving its login form
    /// on. The app's own pre-existing code disagreed with itself about which
    /// one is current (`idp.pennkey.upenn.edu` in
    /// `CanvasSessionRenewer.loginHostMarkers`/docs/CANVAS_LOGIN_HARDENING.md;
    /// the live page fetched 2026-09-16 resolved to
    /// `weblogin.pennkey.upenn.edu`), so both are treated as the login host
    /// rather than picking one — a Penn-side rename, A/B rollout, or regional
    /// redirect must not silently stop auto-fill from ever firing again.
    public static let hosts: [String] = ["weblogin.pennkey.upenn.edu", "idp.pennkey.upenn.edu"]

    /// True when `url` is Penn's IdP login page: the host matches one of
    /// `hosts` (case-insensitive, and a subdomain of one of them also
    /// counts) AND the path starts with `/idp/` — Shibboleth's own
    /// login/SSO namespace, which excludes some unrelated page that happens
    /// to be served from the same host (there is no such page today, but the
    /// path check costs nothing and removes the possibility).
    public static func isLoginForm(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        let matchesHost = hosts.contains { needle in
            host == needle || host.hasSuffix(".\(needle)")
        }
        guard matchesHost else { return false }
        return url.path.hasPrefix("/idp/")
    }

    /// True when `url`'s host contains "duosecurity" — Duo's 2FA
    /// interstitial, reached from Penn's IdP after a correct password. A
    /// substring match, not a suffix match, deliberately: Duo's own frame
    /// hosts (`api-xxxxxxxx.duosecurity.com`) are per-tenant/per-request
    /// subdomains with no fixed suffix to anchor on, the same reasoning
    /// `CanvasSessionRenewer.loginHostMarkers` already uses for this host.
    public static func isDuo(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.contains("duosecurity")
    }

    /// True when `url`'s host is Canvas's own host (or a subdomain of it) —
    /// the SAML round trip completed and landed back on the SP.
    public static func isCanvas(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "canvas.upenn.edu" || host.hasSuffix(".canvas.upenn.edu")
    }

    /// What `fillAndSubmitScript`'s evaluation resolved to.
    public enum Outcome: String, Sendable {
        /// The form was found, filled, and submitted for the first time this
        /// script ran on this page.
        case submitted
        /// `window.__lhfAutoLogin` was already set — a caller re-evaluated
        /// the script on a page it (or an earlier evaluation) already
        /// touched. Treated as "nothing to do," never as a second submit.
        case already
        /// No `#loginform` and no `input[name=j_password]` were found on the
        /// page — this isn't the credential form (or WebKit handed the
        /// script a page WebKit itself hasn't finished settling).
        case noForm = "no-form"
        /// The evaluation result wasn't one of the three strings above —
        /// `evaluateJavaScript` failed outright, or something changed the
        /// script's return shape. Callers treat this exactly like `.noForm`:
        /// nothing was submitted, so there is nothing to react to.
        case unknown
    }

    /// Maps `evaluateJavaScript`'s raw `Any?` completion value to an
    /// `Outcome`. `nil` and anything that isn't the literal string this
    /// script returns are `.unknown` — never a crash, never mistaken for a
    /// real submission.
    public static func outcome(from result: Any?) -> Outcome {
        guard let string = result as? String else { return .unknown }
        return Outcome(rawValue: string) ?? .unknown
    }

    /// JSON-encodes `string` for splicing into the generated JavaScript as a
    /// string literal. `JSONEncoder` is the safe, already-proven-in-this-repo
    /// way to do this (see `CanvasAccessTokenMint.jsonStringLiteral`, the
    /// same technique) — it correctly escapes quotes, backslashes, and
    /// control characters including a raw newline (`\n` becomes the two
    /// characters `\` `n`, never a literal line break inside the generated
    /// script), without hand-rolling escaping rules for a value as sensitive
    /// as a PennKey password. `JSONEncoder` never escapes `/`, so a password
    /// containing something like `</script>` survives as literal characters
    /// inside the JS string — harmless here because this string is handed to
    /// `WKWebView.evaluateJavaScript` as raw JavaScript source, never parsed
    /// as HTML, so there is no surrounding `<script>` tag for it to break out
    /// of.
    private static func jsonStringLiteral(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    /// Builds the script a caller hands to `WKWebView.evaluateJavaScript` to
    /// fill and submit Penn's PennKey credential form.
    ///
    /// Synchronous, single expression, returns one of the raw strings
    /// `Outcome` maps back from. Finds the form by `#loginform` first
    /// (the live markup's own id), falling back to whichever form contains
    /// `input[name=j_password]` in case the id ever changes upstream. Every
    /// path is wrapped in `try`/`catch` so a page shape this script doesn't
    /// expect fails closed as `"no-form"` rather than throwing an
    /// unhandled JS exception back at `evaluateJavaScript`'s completion
    /// handler.
    ///
    /// `window.__lhfAutoLogin` is the one-submission-per-page-load guard:
    /// checked first and set immediately after, before the fields are even
    /// touched, so two overlapping evaluations of this same script (a caller
    /// bug, or WebKit invoking a completion handler late) can never both
    /// reach the submit step. This is a second, independent guard alongside
    /// whatever attempt-counting the caller does in Swift
    /// (`LoginNavigationObserver.autoLoginAttempts`,
    /// `CanvasSessionRenewer`'s own instance flag) — belt and suspenders,
    /// not a replacement for either.
    ///
    /// Submits via the submit *button* (`button.click()`), not
    /// `form.submit()`: Shibboleth needs the button's own
    /// `name="_eventId_proceed"` to arrive in the POST body to pick the
    /// right flow event (see the live markup this was written against,
    /// 2026-09-16) and `form.submit()` never includes a button's name/value
    /// pair. `form.requestSubmit()` (with no button) is the fallback if the
    /// button itself can't be found — it still fires the form's real submit
    /// event, unlike `form.submit()`.
    public static func fillAndSubmitScript(username: String, password: String) -> String {
        let usernameLiteral = jsonStringLiteral(username)
        let passwordLiteral = jsonStringLiteral(password)
        return """
        (function() {
          try {
            if (window.__lhfAutoLogin) { return "already"; }
            var form = document.getElementById('loginform');
            if (!form) {
              var pwField = document.querySelector('input[name="j_password"]');
              form = pwField ? pwField.form : null;
            }
            if (!form) { return "no-form"; }
            window.__lhfAutoLogin = true;
            var userField = form.querySelector('input[name="j_username"]');
            var passField = form.querySelector('input[name="j_password"]');
            if (userField) {
              userField.value = \(usernameLiteral);
              userField.dispatchEvent(new Event('input', { bubbles: true }));
              userField.dispatchEvent(new Event('change', { bubbles: true }));
            }
            if (passField) {
              passField.value = \(passwordLiteral);
              passField.dispatchEvent(new Event('input', { bubbles: true }));
              passField.dispatchEvent(new Event('change', { bubbles: true }));
            }
            var button = form.querySelector('button[name="_eventId_proceed"]');
            if (button) {
              button.click();
            } else if (form.requestSubmit) {
              form.requestSubmit();
            } else {
              form.submit();
            }
            return "submitted";
          } catch (e) {
            return "no-form";
          }
        })();
        """
    }
}

import Foundation
import WebKit

/// Taps Duo's own buttons for the HIDDEN silent renewer, in the foreground
/// only. Owner's rule (Marco, 2026-11-02): the student signs in once and the
/// app never shows a sign-out banner again; on Duo's page the app taps the
/// buttons itself.
///
/// Two taps, both on a `duosecurity.com` host (the main frame or an iframe):
/// 1. "Yes, this is my device" / "Trust browser" / "Remember me": the
///    30-day trust re-issue. Without it the renewal reaches Duo and stops.
/// 2. "Send me a push" (Duo Universal Prompt), including the "Other options"
///    list when the push is not the default. The push lands in Duo Mobile
///    on the student's phone; approving it is the student's one tap. The
///    script reports `"push"` so the renewer can wait up to two minutes for
///    the SAML return instead of 60 seconds.
///
/// Privacy boundary: the script never reads or writes an input's value and
/// never touches a passcode field. The only thing it sends to the app is the
/// word `"push"` or `"trusted"`. The PennKey credential still only ever
/// reaches the IdP's password field (`PennKeyLoginForm`), never this script.
/// On every other host it returns before touching anything, and every error
/// is swallowed so it cannot disturb the page.
///
/// A BACKGROUND attempt must never send a push: nobody is there to approve
/// it and it would buzz the phone unattended. `CanvasSessionRenewer`
/// therefore registers this script and its handler for a foreground attempt
/// only.
///
/// The button texts are assumptions about Duo's DOM that cannot be checked
/// without a device (`-LHFForgetDuoTrust` exercises the push path), which is
/// why each tap is once per page load and a miss simply leaves the attempt
/// to its timeout, exactly as before this existed.
enum DuoPromptAutoTap {
    nonisolated static let handlerName = "lhfDuo"

    enum Event: String {
        case push
        case trusted
    }

    nonisolated static let script: String = """
    (function () {
      try {
        var host = String(location.hostname || "").toLowerCase();
        if (!/(^|\\.)duosecurity\\.com$/.test(host)) { return; }

        var trustRe = /yes,?\\s*this is my device|trust (this )?browser|remember me/i;
        var pushRe = /send me a push|push notification|^\\s*duo push\\s*$/i;
        var otherRe = /other options/i;
        var pushed = false, trusted = false, openedOther = false;

        function say(word) {
          try { window.webkit.messageHandlers.lhfDuo.postMessage(word); } catch (e) {}
        }

        function label(el) {
          return String(el.innerText || el.textContent || el.getAttribute("aria-label") || "")
            .replace(/\\s+/g, " ").trim();
        }

        function candidates() {
          return Array.prototype.slice.call(document.querySelectorAll(
            'button, a, [role="button"], input[type="submit"], input[type="button"]'));
        }

        function find(re) {
          var all = candidates();
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            if (el.disabled) { continue; }
            var text = el.tagName === "INPUT" ? String(el.value || "") : label(el);
            if (text && text.length < 80 && re.test(text)) { return el; }
          }
          return null;
        }

        function pass() {
          try {
            if (!trusted) {
              var t = find(trustRe);
              if (t) { trusted = true; t.click(); say("trusted"); return; }
            }
            if (!pushed) {
              var p = find(pushRe);
              if (p) { pushed = true; p.click(); say("push"); return; }
              if (!openedOther) {
                var o = find(otherRe);
                if (o) { openedOther = true; o.click(); }
              }
            }
          } catch (e) {}
        }

        pass();
        new MutationObserver(pass).observe(document.documentElement,
          { childList: true, subtree: true });
      } catch (e) {}
    })();
    """

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .page)
    }
}

/// Receives `DuoPromptAutoTap`'s two words. Held by the renewer for the
/// length of one foreground attempt and removed from the controller when the
/// attempt ends (`WKUserContentController` retains its handlers strongly).
@MainActor
final class DuoPromptMessageHandler: NSObject, WKScriptMessageHandler {
    private let onEvent: @MainActor (DuoPromptAutoTap.Event) -> Void

    init(onEvent: @escaping @MainActor (DuoPromptAutoTap.Event) -> Void) {
        self.onEvent = onEvent
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let host = message.frameInfo.request.url?.host?.lowercased(),
              host == "duosecurity.com" || host.hasSuffix(".duosecurity.com"),
              let word = message.body as? String,
              let event = DuoPromptAutoTap.Event(rawValue: word)
        else { return }
        onEvent(event)
    }
}

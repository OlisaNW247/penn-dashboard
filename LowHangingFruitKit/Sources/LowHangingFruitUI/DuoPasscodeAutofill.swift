import Foundation
import WebKit

/// Lets iOS offer the SMS verification code "From Messages" above the
/// keyboard when the student types a Duo passcode inside the login pane.
///
/// iOS fills a one-time code from Messages into a web input only when the
/// input carries `autocomplete="one-time-code"`. Duo's Universal Prompt is
/// a single-page app on a `duosecurity.com` host (the main frame or an
/// iframe) and renders its passcode field after load, so whether that
/// attribute is present is outside our control and cannot be checked
/// without a device. This script sets it defensively, and also
/// `inputmode="numeric"` so the number pad comes up. A `MutationObserver`
/// re-runs the pass because the field appears later than document end.
///
/// The wrong fixes: reading the code ourselves from Messages (iOS gives an
/// app no access to it) or typing the value into the field from native
/// code. Both would put the code inside the app.
///
/// Privacy boundary: the script only sets attributes. It never reads or
/// sends an input's value, and it posts no message to the app. The SMS
/// code travels from Messages to Duo's page through iOS's own autofill and
/// never passes through the app. On every host other than `duosecurity.com`
/// the script returns before touching anything, and any error is swallowed
/// so it cannot disturb the login page.
enum DuoPasscodeAutofill {
    nonisolated static let script: String = """
    (function () {
      try {
        var host = String(location.hostname || "").toLowerCase();
        if (!/(^|\\.)duosecurity\\.com$/.test(host)) { return; }

        var specific = [
          'input[name="passcode"]',
          '#passcode-input',
          'input[autocomplete="one-time-code"]'
        ];
        var generic = 'input[type="text"], input[type="tel"], input[type="number"]';

        function looksLikeCode(el) {
          var hay = [el.id, el.name, el.getAttribute("placeholder"),
                     el.getAttribute("aria-label")].join(" ").toLowerCase();
          return hay.indexOf("passcode") !== -1 || hay.indexOf("code") !== -1;
        }

        function mark(el) {
          if (el.getAttribute("autocomplete") !== "one-time-code") {
            el.setAttribute("autocomplete", "one-time-code");
          }
          if (el.getAttribute("inputmode") !== "numeric") {
            el.setAttribute("inputmode", "numeric");
          }
        }

        function pass() {
          try {
            specific.forEach(function (selector) {
              document.querySelectorAll(selector).forEach(mark);
            });
            document.querySelectorAll(generic).forEach(function (el) {
              if (looksLikeCode(el)) { mark(el); }
            });
          } catch (e) {}
        }

        pass();
        new MutationObserver(pass).observe(document.documentElement,
          { childList: true, subtree: true });
      } catch (e) {}
    })();
    """

    @MainActor
    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: .page
        ))
    }
}

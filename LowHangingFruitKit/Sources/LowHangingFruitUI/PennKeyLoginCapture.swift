import Foundation
import WebKit

/// A single submitted credential pair, held only until Canvas verifies the login.
/// Never Codable, published UI state, diagnostics, or a process-wide singleton.
@MainActor
final class PennKeyLoginCapture: NSObject, WKScriptMessageHandler {
    struct Credentials {
        let username: String
        let password: String
    }

    static let handlerName = "smoothPennKeySubmission"
    static let world = WKContentWorld.world(name: "SmoothPennKeySubmission")
    private var credentials: Credentials?
    private var expiresAt: Date?
    private var expiryTask: Task<Void, Never>?
    private(set) var isActive = true

    static func accepts(_ url: URL?, isMainFrame: Bool) -> Bool {
        guard isMainFrame, let url, url.scheme == "https",
              url.port == nil || url.port == 443,
              ["weblogin.pennkey.upenn.edu", "idp.pennkey.upenn.edu"].contains(url.host?.lowercased() ?? ""),
              url.path.hasPrefix("/idp/") else { return false }
        return true
    }

    func receive(username: String, password: String, from url: URL?, isMainFrame: Bool, now: Date = Date()) {
        guard isActive, Self.accepts(url, isMainFrame: isMainFrame) else { return }
        // Replace even an invalid previous attempt so it cannot be saved later.
        clear()
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty,
              username.utf8.count <= 256, password.utf8.count <= 4096 else { return }
        credentials = Credentials(username: username, password: password)
        expiresAt = now.addingTimeInterval(600)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            self?.clear()
        }
    }

    /// Consume only after connectCanvas has verified the authenticated session.
    func take(now: Date = Date()) -> Credentials? {
        defer { clear() }
        guard isActive, let expiresAt, now < expiresAt else { return nil }
        return credentials
    }

    func clear() {
        credentials = nil
        expiresAt = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    func finish() {
        isActive = false
        clear()
    }

    func install(in controller: WKUserContentController) {
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        guard message.name == Self.handlerName,
              origin.protocol == "https", origin.port == 0 || origin.port == 443,
              origin.host.lowercased() == frame.request.url?.host?.lowercased(),
              let body = message.body as? [String: String],
              let username = body["username"], let password = body["password"],
              let action = body["action"], Self.accepts(URL(string: action), isMainFrame: true)
        else { return }
        receive(username: username, password: password, from: frame.request.url, isMainFrame: frame.isMainFrame)
    }

    // Observe submission only. Never preventDefault, submit a form, or modify SAML.
    // The click/Enter paths cover pages that use form.submit() (no submit event).
    static let script = #"""
    (() => {
      const hosts = ['weblogin.pennkey.upenn.edu', 'idp.pennkey.upenn.edu'];
      const allowed = u => u.protocol === 'https:' && (!u.port || u.port === '443') &&
        hosts.includes(u.hostname) && u.pathname.startsWith('/idp/');
      if (window.top !== window || !allowed(new URL(location.href))) return;
      const capture = form => {
        if (!(form instanceof HTMLFormElement)) return;
        const username = form.querySelector('input[name="j_username"]');
        const password = form.querySelector('input[name="j_password"][type="password"]');
        const action = new URL(form.getAttribute('action') || location.href, location.href);
        if (!username || !password || !allowed(action)) return;
        window.webkit.messageHandlers.smoothPennKeySubmission.postMessage({
          username: username.value, password: password.value, action: action.href
        });
      };
      document.addEventListener('submit', e => capture(e.target), true);
      document.addEventListener('click', e => {
        const button = e.target instanceof Element ? e.target.closest('button, input[type="submit"]') : null;
        if (e.isTrusted && button && button.type === 'submit') capture(button.form);
      }, true);
      document.addEventListener('keydown', e => {
        if (e.isTrusted && e.key === 'Enter' && e.target instanceof HTMLInputElement) capture(e.target.form);
      }, true);
    })();
    """#
}

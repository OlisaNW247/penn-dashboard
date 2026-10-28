import Foundation

/// Canvas publishes current_user_id only for an authenticated user in ENV.
/// A Canvas origin, cookie, or public course page alone is not that evidence.
public enum CanvasLoginEvidence {
    public static func canInspect(url: URL?, expectedHost: String) -> Bool {
        guard let url, url.scheme == "https", !expectedHost.isEmpty,
              url.host?.lowercased() == expectedHost.lowercased() else { return false }
        let path = url.path.lowercased()
        return !["/login", "/logout", "/saml", "/oauth"].contains(where: path.contains)
    }

    // Return only a Boolean to Swift; never expose or log the user's id.
    public static let script = """
    (() => {
      const id = window.ENV && window.ENV.current_user_id;
      return (typeof id === 'number' && Number.isInteger(id) && id > 0) ||
        (typeof id === 'string' && /^[1-9][0-9]*$/.test(id));
    })()
    """
}

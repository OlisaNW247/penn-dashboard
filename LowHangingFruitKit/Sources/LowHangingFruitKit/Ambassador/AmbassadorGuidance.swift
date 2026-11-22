import Foundation

/// The copy of `smooth-ambassadors/worker/templates/guidance.json` the app
/// shows when the server sent no `guidance` (an older Worker, or an offline
/// phone with an old cached plan). A test decodes the JSON file and requires
/// equality with this, so the two cannot drift. The literal `{link}` is kept;
/// `filled(_:link:)` swaps in the ambassador's share link at display time.
public enum AmbassadorGuidance {
    public static let bundled = AmbassadorPlan.Guidance(
        footer: "the idea is just to get the name and link out there without sounding too much like an ad. quantity > quality, use your creativity.",
        kinds: [
            .init(
                key: "plug", label: "plug smooth",
                example: .init(
                    text: "what do you guys use to stay on top of assignments",
                    reply: "i use this app {link}"),
                how: "post the question, then reply to yourself."
            ),
            .init(
                key: "sneak", label: "sneak smooth in",
                example: .init(
                    text: "yo that [thing that happened] was crazy. smooth lowk clutch",
                    reply: "{link}"),
                how: "put the smooth link in the comments."
            ),
        ]
    )

    /// Replaces every `{link}`. The server's copy arrives filled already, so
    /// filling it again changes nothing.
    public static func filled(_ text: String, link: String) -> String {
        text.replacingOccurrences(of: "{link}", with: link)
    }
}

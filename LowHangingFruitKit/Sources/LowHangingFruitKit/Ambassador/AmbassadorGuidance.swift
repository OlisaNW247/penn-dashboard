import Foundation

/// The copy of `smooth-ambassadors/worker/templates/guidance.json` the app
/// shows when the server sent no `guidance` (an older Worker, or an offline
/// phone with an old cached plan). A test decodes the JSON file and requires
/// equality with this, so the two cannot drift.
public enum AmbassadorGuidance {
    public static let bundled = AmbassadorPlan.Guidance(
        test: "if it reads like an ad, it's an ad.",
        kinds: [
            .init(
                key: "plug", label: "plug smooth",
                example: .init(
                    text: "psa for anyone who found out about a quiz the morning of: there's an app that pulls canvas and gradescope into one list and rings before stuff is due. called smooth",
                    reply: "smooth for students on the app store"),
                how: "say it like a student would. a tip or a question, never a pitch."
            ),
            .init(
                key: "sneak", label: "sneak smooth in",
                example: .init(
                    text: "to everyone reading the odyssey at 10pm for tomorrow: same. at least smooth told me it's due at 11:59 and not midnight",
                    reply: "smooth for students on the app store"),
                how: "reply to whatever's going viral at your school. smooth comes in sideways, the link goes in a comment."
            ),
        ]
    )
}

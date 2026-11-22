import Foundation

/// The copy of `smooth-ambassadors/worker/templates/guidance.json` the app
/// shows when the server sent no `guidance` (an older Worker, or an offline
/// phone with an old cached plan). A test decodes the JSON file and requires
/// equality with this, so the two cannot drift.
public enum AmbassadorGuidance {
    public static let bundled = AmbassadorPlan.Guidance(
        test: "if it reads like an ad, it's an ad. reply to a thread, not the void.",
        kinds: [
            .init(
                key: "straight", label: "straight",
                rule: "smooth helps you stay on top of assignments. say it like a student would: a tip, or a question.",
                prompts: [
                    "ask what people use to not miss assignments, then answer yourself later.",
                    "a tip post: the one thing that fixed your deadlines this semester.",
                    "a complaint about canvas or gradescope, and what you do about it.",
                ],
                examples: [
                    .init(key: "question", text: "what do you guys use to stop missing assignments?", reply: "smooth for students on the app store"),
                    .init(key: "tip", text: "psa for anyone who found out about a quiz the morning of: there's an app that pulls canvas and gradescope into one list and rings before stuff is due. called smooth. changed my semester", reply: "smooth for students on the app store"),
                    .init(key: "canvas", text: "canvas hiding due dates in three different places should be illegal. smooth puts them in one list, that's the whole app, that's all i wanted", reply: "smooth for students on the app store"),
                ]
            ),
            .init(
                key: "misc", label: "misc",
                rule: "any post about anything at your school. smooth comes in sideways. the link goes in a comment or your bio, never the post.",
                prompts: [
                    "reply to whatever is going viral right now, then add smooth in a comment.",
                    "a ranking or a list where smooth is one item among real campus things.",
                    "the late-night post: the library, the dining hall, the reading nobody did.",
                ],
                examples: [
                    .init(key: "odyssey", text: "to everyone reading the odyssey at 10pm for tomorrow: same. at least smooth told me it's due at 11:59 and not midnight", reply: "smooth for students on the app store"),
                    .init(key: "ranking", text: "midterm week power ranking\n1. sleep\n2. the dining hall at 10pm\n3. smooth telling me i have a quiz tomorrow\n4. everything else", reply: "smooth for students on the app store"),
                    .init(key: "library", text: "the library at 1am is its own ecosystem. the only thing keeping me in here is smooth saying i have two things due", reply: "smooth for students on the app store"),
                    .init(key: "survival", text: "things that got me through this week: iced coffee, the outlets on the 3rd floor, smooth", reply: "smooth for students on the app store"),
                ]
            ),
        ]
    )
}

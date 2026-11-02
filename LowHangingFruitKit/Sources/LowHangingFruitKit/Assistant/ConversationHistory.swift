import Foundation

/// The earlier turns of the conversation on screen, shaped and capped for the
/// `history` field of an `ask` request.
///
/// **Why this exists (2026-11-02).** The phone used to send `history: []` on
/// purpose, because earlier turns leaving the phone is a privacy-policy
/// change. The cost showed on the owner's phone: told "You should've said that
/// in my original question", the tree answered "I don't have the original
/// question you asked", because as far as the server knew there was only ever
/// one message. The owner approved sending the conversation, and
/// `docs/PRIVACY.md` now says so. The server already accepts the field and
/// keeps the last 10 turns and 8,000 characters (`capHistory` in
/// `backend/supabase/functions/_shared/prompt.ts`); the phone sends less than
/// that on purpose, so a long chat does not make every later question cost
/// more.
///
/// Pure and clock-free. The transcript lives in `AssistantConversation`
/// (UI layer); this type only turns a snapshot of it into turns.
///
/// **What the rules are.**
/// - A message that is still streaming, and a message with no text (a reply
///   that never arrived), are skipped: neither is something the model said.
/// - Student becomes `user`, assistant becomes `assistant`. The text is as the
///   transcript shows it: the student's words as typed, the assistant's text
///   without its `<sources>` block, which the splitter already removed.
/// - Only the last `maxMessages` survive, then whole turns are dropped from
///   the front, oldest first, until the characters fit `maxCharacters`. A turn
///   is never cut in the middle: half an answer reads as the model's own
///   words. The newest turn is always kept even if it alone is over the cap,
///   as the server does, rather than sending nothing for a long last answer.
/// - A history that would begin with an assistant turn (its question fell off
///   the front) drops that turn too, so the model never opens on a reply to a
///   question it was not shown.
public enum ConversationHistory {
    /// Three exchanges. Enough for "what about the final?" and "you should
    /// have said that earlier", not so many that every question carries a
    /// whole session.
    public static let defaultMaxMessages = 6
    public static let defaultMaxCharacters = 6000

    /// One transcript entry, stripped to what the cap needs. The UI maps its
    /// own message type onto this; the Kit never sees `AssistantMessage`.
    public struct Message: Sendable, Equatable {
        public enum Role: Sendable, Equatable {
            case student
            case assistant
        }

        public var role: Role
        public var text: String
        /// True while the reply is still arriving.
        public var isPending: Bool

        public init(role: Role, text: String, isPending: Bool = false) {
            self.role = role
            self.text = text
            self.isPending = isPending
        }
    }

    public static func turns(
        from messages: [Message],
        maxMessages: Int = ConversationHistory.defaultMaxMessages,
        maxCharacters: Int = ConversationHistory.defaultMaxCharacters
    ) -> [AskTurn] {
        guard maxMessages > 0 else { return [] }

        var turns: [AskTurn] = []
        for message in messages {
            if message.isPending { continue }
            if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            turns.append(AskTurn(
                role: message.role == .student ? "user" : "assistant",
                content: message.text
            ))
        }

        if turns.count > maxMessages {
            turns = Array(turns.suffix(maxMessages))
        }

        var total = turns.reduce(0) { $0 + $1.content.count }
        while total > maxCharacters, turns.count > 1 {
            total -= turns.removeFirst().content.count
        }

        while let first = turns.first, first.role == "assistant" {
            turns.removeFirst()
        }
        return turns
    }
}

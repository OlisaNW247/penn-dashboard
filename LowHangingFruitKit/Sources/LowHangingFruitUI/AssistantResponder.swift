import Foundation

// MARK: – What answers a question
//
// This branch is a UI study, so the only responder that exists is a scripted
// one. The point of the protocol is that the screen never learns that: it
// asks for an `AsyncStream` of chunks and renders whatever arrives, so
// swapping the script for a real Claude call is a one-type change at the call
// site in `AssistantView` and touches no view code.
//
// Streaming rather than a single returned string is deliberate even for the
// script. A chat UI's whole feel — when the thinking indicator goes away, how
// the answer lands, whether the scroll keeps up with the text — is a property
// of *incremental* arrival. A prototype that returns finished paragraphs
// instantly looks fine and then falls apart the first time it is wired to a
// live model, which is precisely the risk this study exists to retire.

/// A source the assistant leaned on, shown as a chip under the answer.
///
/// Citations are the product idea here, not decoration. "The assistant told me
/// two absences are free" is worth nothing if the student cannot check it
/// before skipping a third lecture, and an academic assistant that quietly
/// invents a policy is worse than no assistant. Every scripted answer below
/// carries its sources for that reason.
struct AssistantCitation: Identifiable, Hashable, Sendable {
    var id: String { "\(course)-\(source)-\(detail ?? "")" }
    var course: String
    var source: String
    var detail: String?
}

/// One incremental piece of an answer.
enum AssistantChunk: Sendable {
    case text(String)
    case citations([AssistantCitation])
}

/// What the responder is allowed to know about the student.
///
/// `courseCodes` is the whole of it for the scripted stand-in. The real
/// backend (`ClaudeAssistantResponder`) needs more — the syllabus, deadline
/// and announcement text those codes name — which is what the two fields
/// below carry. Widening this struct *is* the privacy review this type's
/// original comment pointed at: `contextDocument` is the one piece of LHF
/// data that ever leaves the device, and it only does when the student has
/// supplied their own Anthropic key (see the file comment atop
/// `ClaudeAssistantResponder.swift`).
struct AssistantContext: Sendable {
    var courseCodes: [String]

    /// The student's class data, pre-rendered as a byte-stable document.
    /// Built elsewhere; this type only carries it. "Byte-stable" matters
    /// more than it sounds like it should: `ClaudeAssistantResponder` marks
    /// this string as a prompt-cache breakpoint, and a cache is a prefix
    /// match, so whoever renders this document must produce the identical
    /// bytes turn over turn for a fixed set of underlying data, not merely
    /// equivalent-looking text (stable key order, stable whitespace, no
    /// embedded "generated at" timestamp).
    var contextDocument: String = ""

    /// The moment the question was asked. Deliberately NOT baked into
    /// `contextDocument` — see the long comment on the cache breakpoint in
    /// `ClaudeAssistantResponder.reply(to:context:)` for why: prompt caching
    /// is a prefix match, and a value that changes on every request (a
    /// timestamp, "today's date") sitting inside the cached prefix would
    /// invalidate the cache on every single turn, silently turning a
    /// designed-to-be-cheap-and-fast path into the most expensive possible
    /// one. This field exists so the current date can still reach the model
    /// — just after the breakpoint, in the per-turn user message, where a
    /// change costs nothing. (See the "wrong fix" callout in
    /// `ClaudeAssistantResponder` — putting the date in the cached document
    /// is the obvious-looking move that silently zeroes the cache hit rate.)
    var askedAt: Date = Date()
}

protocol AssistantResponder: Sendable {
    func reply(to prompt: String, context: AssistantContext) -> AsyncStream<AssistantChunk>
}

// MARK: – The stand-in

/// Answers from a small table of hand-written responses, streamed a word at a
/// time.
///
/// Matching is a bag-of-keywords score, not a parser. It only has to be right
/// enough that tapping a suggested question, or typing a close paraphrase of
/// one, produces the answer the design was drawn around — that is what makes a
/// prototype demonstrable on a real device rather than only in screenshots.
struct ScriptedAssistantResponder: AssistantResponder {
    /// Milliseconds between words. Around 28ms reads like a fast model: quick
    /// enough not to test patience, slow enough that the streaming is legible
    /// as streaming.
    var wordDelay: UInt64 = 28

    /// How long to sit on the thinking indicator before the first word. Real
    /// latency to first token is most of a second, and designing against
    /// instant responses hides whether the waiting state actually holds up.
    var leadIn: UInt64 = 620

    func reply(to prompt: String, context: AssistantContext) -> AsyncStream<AssistantChunk> {
        let answer = Self.answer(for: prompt, context: context)
        let delay = wordDelay
        let lead = leadIn
        return AsyncStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: lead * 1_000_000)
                // Split on spaces but keep them, so the reassembled text has
                // its original spacing and newlines survive intact.
                for word in answer.body.splittingKeepingSeparators() {
                    if Task.isCancelled { break }
                    continuation.yield(.text(word))
                    try? await Task.sleep(nanoseconds: delay * 1_000_000)
                }
                if !answer.citations.isEmpty {
                    continuation.yield(.citations(answer.citations))
                }
                continuation.finish()
            }
        }
    }

    // MARK: The script

    struct Scripted: Sendable {
        var keywords: [String]
        var body: String
        var citations: [AssistantCitation]
    }

    static func answer(for prompt: String, context: AssistantContext) -> Scripted {
        let haystack = prompt.lowercased()
        let best = scripts
            .map { script -> (Scripted, Int) in
                (script, script.keywords.filter { haystack.contains($0) }.count)
            }
            .max { $0.1 < $1.1 }
        guard let best, best.1 > 0 else { return fallback(context: context) }
        return fill(best.0, asking: prompt, context: context)
    }

    /// Which class the question is about.
    ///
    /// Full code first ("cis 1210"), then the department on its own, because
    /// "what's my phys attendance policy" is how the question actually gets
    /// typed — nobody includes the catalogue number when they are talking
    /// about their own timetable. Falls back to the student's first class.
    static func course(asking prompt: String, context: AssistantContext) -> String {
        let haystack = prompt.lowercased()
        if let exact = context.courseCodes.first(where: { haystack.contains($0.lowercased()) }) {
            return exact
        }
        let byDepartment = context.courseCodes.first { code in
            guard let department = code.split(separator: " ").first else { return false }
            return haystack.contains(department.lowercased())
        }
        return byDepartment ?? context.courseCodes.first ?? placeholderCodes[0]
    }

    /// Substitutes the student's real classes into a scripted answer.
    ///
    /// Without this the prototype contradicts itself on screen: asked about
    /// CIS 1210 it answered with CIS 1210's name in the bubble and PHYS 0151
    /// in the citation chips underneath, which is exactly the failure mode
    /// the citations exist to rule out. A demo that visibly cites the wrong
    /// class teaches the reviewer to distrust the feature.
    static func fill(_ script: Scripted, asking prompt: String, context: AssistantContext) -> Scripted {
        let subject = course(asking: prompt, context: context)
        let codes = context.courseCodes.isEmpty ? placeholderCodes : context.courseCodes
        func apply(_ text: String) -> String {
            var out = text.replacingOccurrences(of: "{course}", with: subject)
            for slot in 0..<3 {
                out = out.replacingOccurrences(of: "{c\(slot)}", with: codes[slot % codes.count])
            }
            return out
        }
        var filled = script
        filled.body = apply(script.body)
        filled.citations = script.citations.map {
            AssistantCitation(course: apply($0.course), source: $0.source, detail: $0.detail)
        }
        return filled
    }

    /// Only reached when the student has no classes synced yet.
    static let placeholderCodes = ["PHYS 0151", "PSYC 1010", "ACCT 1010"]

    /// The hero case from the brief — "what's my phys attendance policy" — is
    /// first, and is written the way a good answer to it actually reads:
    /// the number up front, the exception second, the thing that trips people
    /// up third. No preamble, no restating the question.
    static let scripts: [Scripted] = [
        Scripted(
            keywords: ["attendance", "absence", "absent", "skip", "miss class"],
            body: """
            Two unexcused absences cost you nothing. From the third onward each \
            one takes 2% off your final grade, to a maximum of 10%.

            Labs are counted separately and are stricter: a missed lab has to be \
            made up in the same week or it scores zero.

            The part people get caught by — an absence is only excusable if you \
            file it *before* the session. Retroactive requests are declined \
            except for documented medical or family emergencies.
            """,
            citations: [
                AssistantCitation(course: "{course}", source: "syllabus", detail: "§4 attendance, p.2"),
                AssistantCitation(course: "{course}", source: "announcement", detail: "aug 26"),
            ]
        ),
        Scripted(
            keywords: ["exam", "midterm", "final", "test", "quiz"],
            body: """
            Your next one is the {c1} midterm, Thursday 11 Sep, 6:00–8:00pm \
            in Meyerson B1.

            It covers lectures 1–9 and chapters 1–5 — everything through social \
            cognition, not including the memory unit.

            After that: {c0} midterm 1 on 23 Sep, and the {c2} quiz on \
            16 Sep, which is online and open for 24 hours.
            """,
            citations: [
                AssistantCitation(course: "{c1}", source: "syllabus", detail: "schedule, p.4"),
                AssistantCitation(course: "{c1}", source: "canvas", detail: "midterm 1"),
            ]
        ),
        Scripted(
            keywords: ["worth", "weight", "count", "percent", "grade break", "how much"],
            body: """
            {course} breaks down as: problem sets 20%, labs 15%, two midterms \
            20% each, final 25%.

            The lowest problem set is dropped, which is worth knowing before you \
            burn a late day on one.

            Labs have no drop, and the final is not cumulative in the way people \
            assume — it is weighted toward the back half of the course.
            """,
            citations: [
                AssistantCitation(course: "{course}", source: "syllabus", detail: "§2 grading, p.1"),
            ]
        ),
        Scripted(
            keywords: ["late", "extension", "deadline pol", "turn in late"],
            body: """
            {c0} gives you four late days for the semester, at most two on \
            any one problem set. After that it is 10% a day.

            {c1} has no late policy at all — Canvas closes the submission \
            and the score stands at zero.

            {c2} wants extension requests through the course form, at least \
            24 hours ahead.
            """,
            citations: [
                AssistantCitation(course: "{c0}", source: "syllabus", detail: "§3 late work"),
                AssistantCitation(course: "{c1}", source: "syllabus", detail: "§policies"),
            ]
        ),
        Scripted(
            keywords: ["missing", "behind", "outstanding", "owe", "what do i need", "todo"],
            body: """
            Three things are actually outstanding.

            {c0} problem set 3 is overdue by two days — you have late days \
            left, so this one is recoverable.

            {c1} chapter 4 problems are due tonight at 11:59pm.

            {c2} homework 2 is due Friday. The {c1} reading is marked \
            nothing-to-submit, so it is not blocking you.
            """,
            citations: [
                AssistantCitation(course: "{c0}", source: "canvas", detail: "problem set 3"),
                AssistantCitation(course: "{c1}", source: "canvas", detail: "ch.4 problems"),
            ]
        ),
        Scripted(
            keywords: ["office hour", "ta ", "professor", "instructor", "email"],
            body: """
            {course} office hours are Tuesday 2–4pm and Thursday 10–11:30am in \
            DRL 3N6. TA sessions run Wednesday evenings 7–9pm in DRL 2C4.

            Professor Reyes prefers questions in the Canvas discussion over \
            email — the syllabus says email replies can take three days, and the \
            board is usually answered the same evening.
            """,
            citations: [
                AssistantCitation(course: "{course}", source: "syllabus", detail: "§1 contact, p.1"),
            ]
        ),
    ]

    /// When nothing matches, say what is actually known rather than
    /// apologising. A stand-in that cheerfully bluffs would teach the wrong
    /// lesson about how the real thing should behave when it is unsure.
    static func fallback(context: AssistantContext) -> Scripted {
        let classes = context.courseCodes.isEmpty
            ? "your classes"
            : context.courseCodes.prefix(4).joined(separator: ", ")
        return Scripted(
            keywords: [],
            body: """
            I have the syllabi, deadlines and announcements for \(classes) — \
            but nothing in them answers that directly.

            Try asking about a policy (attendance, late work, grade weighting), \
            a date, or what you currently owe.
            """,
            citations: []
        )
    }
}

private extension String {
    /// Splits into word-sized pieces that still carry their trailing
    /// whitespace, so `pieces.joined()` is exactly the original string.
    /// Streaming word-by-word and then re-adding spaces by hand is how
    /// paragraph breaks get eaten.
    func splittingKeepingSeparators() -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in self {
            current.append(character)
            if character == " " || character == "\n" {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

# v4 — what changed, in plain language

_Started 2026-08-23 on branch `v4`. This is the running changelog for the
release, written for a person rather than for a diff._

v4 has two halves. The first is **closing out v3**: three branches of finished
but unmerged work — one of which was quietly corrupting data on disk — plus the
plain-language documentation of what the app now does with your information
(`docs/persistence-explained.md`, `docs/database-explained.md`, and this file).
The second is **the profile half**: a real home for "these are my classes, this
is how I want to hear about each one," a way to add a class the Canvas feed
hasn't mentioned yet, and the semester rollover that lets the app survive
September without either hiding your work or burying you in last spring's.

The design reasoning behind all of it is in `docs/v4-plan.md`. This file is the
outcome, not the argument.

---

## How to add to this file

> **For whoever lands the next workstream — human or agent.**
>
> Entries are **appended to the bottom of the Changes section**, in the order
> they land, so the file reads as a running log. Do not reorder or rewrite
> earlier entries; if something later supersedes an earlier change, add a new
> entry saying so.
>
> Every entry uses the same three-part shape, and all three parts are required:
>
> ```markdown
> ### A plain-language title, in the user's words
>
> **What changed.** The mechanism, in ordinary sentences. Name the file or type
> if it helps someone go look, but explain the behaviour before naming anything.
>
> **Why it mattered.** What was wrong before, and what it cost. If the change is
> a bug fix, this is where the bug goes — described by its symptom, not its
> stack trace.
>
> **What you'll notice.** The observable difference, from the outside. "Nothing,
> if it was already working for you" is a perfectly good answer and is often the
> honest one.
>
> _Workstream / source, one line._
> ```
>
> Keep it to what the code supports. A changelog that promises something the
> build doesn't do is worse than one with a gap in it.

---

## Changes

### The splash no longer interrupts your music

**What changed.** The launch animation now asks iOS to *share* the audio system
instead of taking it over. Before playing, it puts the shared audio session into
the `.ambient` category with the `.mixWithOthers` option; previously it
configured nothing at all.

**Why it mattered.** The obvious explanation was wrong, and chasing it would
have wasted a day. The splash clip has no sound and never did — both
`splash.mp4` and `splash_dark.mp4` are video-only, a single h264 stream with no
audio track, and the player was already explicitly muted. There was nothing to
turn down.

The actual mechanism is that **starting video playback at all** makes iOS
activate the app's shared audio session, and an app that has never configured
one gets the system default, `.soloAmbient` — which means, in as many words,
"stop everyone else's audio." Spotify was being paused by the act of the session
becoming active, not by any sound LHF made. Muting harder, or re-encoding the
files to strip an audio track that wasn't there, would have changed nothing.

**What you'll notice.** Music, a podcast, or anything else playing keeps playing
when you open the app.

_W1 — `SplashView.swift`._

---

### Three branches of finished work were merged in

**What changed.** Three completed but unmerged branches from the v3 era were
brought onto `v4` as the first thing v4 did. The most important of the three
fixes a bug that was writing wrong data to disk. The other two harden the Canvas
login and unblock App Store review.

**Why it mattered.**

*Work you'd turned in could come back as owed — permanently.* When the app
refreshes grades, it asks Canvas about each of your courses in turn and records
what you've submitted. The step that writes that to disk is a deliberate full
replace, not a merge, because it has to be able to *un*-mark something: if a
submission is retracted or a TA clears it, the app must be able to go back to
"not turned in."

The bug was that a refresh which only covered *some* of your courses handed that
replace its partial answer. Every course the refresh had skipped got written
down as "nothing submitted." What made it nasty is that the session you were
sitting in looked completely correct — the on-screen list was computed from the
right, complete answer. The damage was on disk, and it only surfaced on the next
cold launch, when the app seeded itself from the ledger and bounced finished
work back onto your dashboard. And because every subsequent partial refresh
wrote the same wrong answer again, it didn't heal on its own.

Reaching it took nothing exotic: one course failing mid-loop (a concluded course
returning a 401 is enough), or simply switching a class off in the picker.

*The Canvas login was fragile in specific, reproducible ways.* The merged work
tracks real cookie expiry so a dead cookie is never replayed, isolates the
Canvas and Gradescope cookie stores from each other, purges the web session
properly on disconnect, and adds a "reset login data" escape hatch for the
"Stale Request" dead end that could otherwise only be cleared by deleting the
app. It also brings ledger schema versioning and honest reporting when a save
actually fails, instead of a silent `try?`.

*An App Store reviewer could get permanently locked out.* Reviewers can't get
past Penn SSO, so the app offers "Preview with sample data" instead. But that
link only appeared on the first pane of the intro carousel, and tapping **Skip**
— the single most ordinary thing to do with an intro carousel — set a flag that
routed straight to onboarding, where the link had been deliberately removed.
Nothing short of deleting and reinstalling brought it back. Separately, every
"Connect…" row in Settings silently dropped preview mode, so a reviewer
following the review notes to the gear icon was ejected from the demo with no
way back. The preview entry point now appears in both places, and in preview
mode those Settings rows collapse to one clearly-labelled "Exit preview and
connect my Canvas" so that leaving is always deliberate.

Also folded in: the widget was missing its `CA92.1` privacy declaration, which
is an automated `ITMS-91053` rejection; a whitespace bug in course-code parsing
that could hide whole courses; and VoiceOver labelling on the dashboard's
primary tab control.

**What you'll notice.** If the submission bug had hit you, work you'd already
turned in stops reappearing as owed. Canvas sign-in gets stuck less often, and
when it does there's a way out that isn't reinstalling. Everything else is
invisible unless you're the one submitting the app.

_W0 — merges of `claude/lhf-submission-freshness`,
`claude/lhf-ship-safe-fixes`, and
`origin/claude/lhf-v3-canvas-merge-6msbyo`._

---

_More entries are appended here as each workstream lands._

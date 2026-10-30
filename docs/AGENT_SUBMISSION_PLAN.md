# Agents and Smooth: Smooth is the hands, not the key

_Design record, written 2026-10-30 from research only. Nothing here is
built. The research report it rests on is
`docs/research/agents-acting-on-canvas-via-smooth.md`, with the five
source notes beside it; every claim there is tagged primary source,
search summary, or repo. Same register as `docs/CHROME_EXTENSION.md`:
why first, then how._

## The owner's ask (2026-10-30)

Marco wants a student to connect an agent (OpenAI's "dots", Meta's Muse,
Anthropic's Claude Duet, or an ordinary Claude or ChatGPT connector) to
Smooth, so the student can say: "see my pending assignment on Smooth,
open the link, do it, and turn it in." His own framing of the hard part:
agents get signed out of Canvas; Smooth does not. So there would have to
be somewhere to share Smooth's sign-in with the agent.

## The finding: the sign-in cannot be lent, and it is the wrong thing to lend

What keeps Smooth signed in at Penn is not the Canvas cookie. It is the
renewal *process*: a hidden `WKWebView`, in the foreground, re-walking
Penn's SAML chain with the identity-provider and Duo cookies that live in
Smooth's own WebKit data store, plus the saved PennKey password
(`CanvasSessionRenewer`, `PennKeyCredentialStore`; CLAUDE.md → Stay
signed in). None of that travels with the cookie.

The cookie an export would hand over is a Rails session whose default
server-side life is one day (`expire_after 1.day` in canvas-lms, read
from source), and which Smooth itself treats as dead 24 hours after its
last save. Duo's "remember this browser" trust is bound to the browser
that earned it. Penn disables student access tokens, the scoped
credential that would make this clean (CLAUDE.md → Penn restricts
student Canvas access tokens). So a cloud agent holding Smooth's cookie
would be signed out within a day, with no way back in short of the
student typing PennKey and Duo into the agent's own browser.

And no agent platform offers a developer-facing way to inject a session.
dots, Duet and Muse each hold their own cloud browser and hand it to the
human at a login wall. Claude and ChatGPT connectors speak MCP, which is
a tool protocol, not a cookie channel. Anthropic separately forbids
third parties from intermediating Claude credentials
(`docs/AI_ACCOUNT_LINKING.md`); the symmetric move, Smooth handing its
credential to Claude, has no sanctioned shape either.

The wrong fix, and it looks reasonable for about a day: export the
Keychain cookies to the agent or to a cloud browser (Browserbase, Steel,
Anchor and the like). It works once, breaks silently within 24 hours,
leaves a bearer credential for the student's whole Canvas account on a
machine Smooth does not control, and contradicts the privacy line
Smooth has published since `docs/PRIVACY.md` existed: cookies never
leave the phone.

## The reframe: Smooth submits, the agent only thinks

Flip it. Instead of moving the sign-in to where the agent is, move the
agent's output to where the sign-in already is. Smooth already holds the
assignment (title, description, attached files, due date), the
submission state, and a live session it uses for read-only Canvas API
calls. Canvas accepts cookie-authenticated API writes as long as the
request carries the CSRF token (`X-CSRF-Token`, from the `_csrf_token`
cookie in Smooth's own jar; `lib/authentication_methods.rb` and
`application_controller.rb` in canvas-lms). So Smooth can be the
submitter.

The flow:

1. The agent asks Smooth for pending work, through an MCP server. The
   natural home is the Supabase backend, which already receives the one
   kind of Canvas content Smooth sends off-device (pooled course
   material, assignment descriptions included).
2. The agent produces the answer: text, a file, a URL.
3. The agent hands the draft back through the same channel. The phone
   shows a visible notification: "Your agent drafted PHYS 151 HW 4.
   Review and submit?"
4. The student opens it, reads the draft, taps submit. Smooth POSTs to
   the Submissions API with its own session, in the foreground.

The foreground tap is not a workaround for iOS background limits. It is
what makes the design defensible: every submission is confirmed by the
student, on the student's device, and the agent never holds the power to
submit. The credential never moves. The backend's first principle in
`backend/PROTOCOL.md`, the server never talks to Canvas, still holds.

## What limits it

- **Assignment types.** The Submissions API takes text entry, URL, file
  upload, media recording and student annotation, and Classic Quizzes
  have start and complete endpoints. New Quizzes, LTI tools and
  Gradescope have no student submission API. For those, Smooth can only
  deep-link the student to the page, where the agent-in-browser path
  below takes over.
- **A first write path.** Smooth has never written to Canvas. The ledger
  invariant is "nothing the student did is ever lost"; a duplicate or
  half-failed POST is a new class of bug, and a submission is not
  retractable the way a completion swipe is. Idempotency (one draft, one
  submission id, recorded in the ledger before the POST) is the whole
  design problem here.
- **Store and forward, not a live link.** Silent push gives about 30
  seconds, is throttled to a few per hour, and never wakes a force-quit
  app; background refresh crashes anyway (CLAUDE.md → background-refresh
  trap). The draft waits in the backend until the student opens the
  notification. That matches the confirm-on-phone model, so it costs
  nothing.
- **Apple review.** Guideline 5.1.2(i) (page dated 2026-10-16) requires
  disclosure and explicit permission before sharing personal data with a
  third-party AI. The assignment text is the student's data; the opt-in
  has to be its own screen, and `docs/PRIVACY.md` has to change in the
  same commit. Guideline 5.2.2 requires that Canvas's terms permit the
  access; Instructure's API policy defers to the school's
  academic-integrity rules and bars use "on behalf of any third-party".
  Smooth acting for the student is the same footing as today's read
  calls; the agent producing the content is new.
- **Academic integrity is the student's exposure, but Smooth makes it
  one tap.** Anthropic's usage policy forbids submitting AI-assisted
  work without permission or attribution; OpenAI's lists academic
  dishonesty (that one read through a search summary). Decide on purpose
  whether the product is "draft and review" or "do it and turn it in".
  The first is a study tool with a submit button; the second is the
  thing every platform's consequential-action prompt exists to slow
  down. Penn's Code of Academic Integrity text was not retrieved.
- **Penn only, for now.** The MCP server keys on the backend's anonymous
  account, which only Penn installs have. Other schools are fully
  on-device, so for them only the App Intents path applies.

## The other paths, ranked

The report ranks six architectures. In order:

1. **App Intents on the phone.** Expose the work list to Siri, Shortcuts
   and Apple Intelligence as entities and intents. No data leaves the
   phone; `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is
   documented as fine for background intent runs. This is the cheapest
   "agent can see my Smooth" and works at every school. It cannot drive
   a web page.
2. **The student's own signed-in browser.** Claude in Chrome and the
   ChatGPT extension act in the student's own Chrome profile, where
   Canvas and Duo trust are already alive. Zero Smooth changes; today
   the only path where "open, do, turn in" works end to end. The Smooth
   Chrome extension (`docs/CHROME_EXTENSION.md`, "a helper for the
   phone") is the natural place to hand such an agent a deep link and
   the assignment context.
3. **Smooth as submitter** (this document). The only "agent acts"
   design that keeps the credential on the phone and a human on the
   button.
4. **Mac companion with a local MCP server.** The Mac build exists; a
   stdio or localhost MCP server with typed tools (list, fetch, submit
   with confirmation) that Claude Desktop, Claude Code or the ChatGPT
   desktop app drives. The Mac must sign in to Canvas itself: the
   phone's cookies are ThisDeviceOnly and never sync. Same design as 3,
   same machine as the agent, no push queue.
5. **Phone as authenticated proxy.** Rejected: the 30-second push
   window, the hourly throttle, force-quit, and a local-network listener
   that stops on suspension (an Apple engineer's own advice). No iPhone
   precedent found.
6. **Cookie export**, to the agent or a cloud browser. Rejected, for the
   reasons in the finding above.

## If this goes ahead

Steps, each verifiable alone, in the order the dependencies run:

1. **Read-only MCP server** on the backend: `list_pending`,
   `get_assignment` (description, attachments, due, submission state),
   behind a per-install opt-in token the student creates in Profile.
   Changes `backend/PROTOCOL.md` and `docs/PRIVACY.md` in the same
   commit. No write tool, ever, on this server.
2. **Draft inbox**: a `drafts` table the agent writes to and the phone
   reads; a visible push on insert; a review sheet in the app.
3. **The submit path**, phone-side only: `CanvasSubmissionClient` in
   the Kit (cookie plus CSRF, the three-step file upload), a ledger row
   recording the attempt before the POST, and the confirm sheet. Test
   against fixtures first; then one real submission to a sandbox
   assignment in a course the owner teaches or controls, never a graded
   one, before anyone else sees it.
4. **App Intents** can go first or in parallel; they share nothing with
   the above.

A change that has not been compiled is not done; nothing above has been.

## Three things the research turned up in passing

- The analytics-cookie fix (`gatedOnLiveSession`) exists only
  uncommitted and uncompiled on `codex/simplify-canvas-onboarding`;
  CLAUDE.md still calls it unfixed, and the live build does not have it.
- `AssistantContextDocument` renders each item as done, outstanding or
  nothing to submit, while `docs/PRIVACY.md` says completion state is
  excluded from what ask sends. Unverified whether the server path
  includes it; if it does, one of the two has to change.
- Several Apple-guideline and vendor-policy quotes in the report came
  through a summarising fetch or a search summary. Re-read the page
  before quoting any of them in an App Review note.

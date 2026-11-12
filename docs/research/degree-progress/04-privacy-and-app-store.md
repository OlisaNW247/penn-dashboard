# 04 - Privacy and the App Store (degree-progress research)

Written 2026-11-09 by the synthesising session, not a researcher agent.
Labels: [read directly] = fetched this session; [repo] = read from this repo; [inferred] = reasoning.

## What the design must keep on the phone

From the privacy posture in `CLAUDE.md` (top) and `docs/PRIVACY.md` (2026-11-05) [repo]:
grades, completions, submission state, the work list, the student's name and
every credential never leave the phone. A degree record is the same class of
data as grades, and in one respect more sensitive: a transcript names every
course a student took and when. So, [inferred] everything below is on-device
only, in its own SwiftData store file (the `AppliedFactStore` pattern, never
the ledger's schema; see note 08 section 3), never in the backend, never in
the laptop sync's first version, and never in the tree's context document
unless `docs/PRIVACY.md` is changed first:

- which program(s) the student picked, and the catalog year;
- the courses the student marked as taken, in progress or planned, with terms;
- the engine's result (which requirement each course was applied to);
- any per-student override ("count this course here");
- any imported audit PDF or its parsed text, if that route is ever built;
- any Path@Penn session, if that route is ever built (Keychain, this-device-only).

A degree plan is also the student's own work, so it belongs in the "nothing
the student did is ever lost" class: it must not be purged when Canvas is
disconnected (unlike facts and enrollment rows), and it must survive a reinstall
only in the way the ledger does today (it does not; that is accepted).

## What can be shared safely

Degree requirement templates carry nothing personal: they are the registrar's
rules for a program and catalog year, the same for every student. They are the
same class as pooled course material and the `catalog_courses` table (public
registrar data, readable by every authenticated caller, written only by the
server; `backend/supabase/migrations/20260907120000_catalog.sql`) [repo].
Likewise course facts needed for planning (prerequisite text, credits, which
semesters a course was offered) are public catalog data. A `degree_programs`
table copying the `catalog_courses` RLS block is fine; a server column holding
a student's chosen major, taken courses or plan is not.

## What docs/PRIVACY.md would have to say

Version 1 (templates plus marked courses, on-device, the tree not told):
one bullet under "What stays on your phone":

> **Your degree plan.** The program you pick, the courses you mark as taken
> or planned, and what Smooth works out from them stay on this phone. The
> requirement lists themselves are public registrar data that every copy of
> Smooth downloads; nothing about you is in them. Smooth's reading is not an
> official audit: Path@Penn is.

If the tree is given degree facts (a later phase), the "Questions you ask the
tree" paragraph must add that the summary carries the program and the
requirement status words, and the privacy posture paragraph in `CLAUDE.md`
changes in the same commit (the table at the top of `CLAUDE.md` says so).

If a Path@Penn reading route is ever built, a new section like "Automatic
Canvas reconnection" is needed: what is read, that it stays on the phone,
that the PennKey already saved is reused and goes only to Penn's login page,
and how to remove it.

## Apple guidelines, quoted from the current text

Read directly from https://developer.apple.com/app-store/review/guidelines/
on 2026-11-09 [read directly].

**5.1.1 Data Collection and Storage**

(i) Privacy Policies: "All apps must include a link to their privacy policy
in the App Store Connect metadata field and within the app in an easily
accessible manner. The privacy policy must clearly and explicitly: Identify
what data, if any, the app/service collects, how it collects that data, and
all uses of that data. Confirm that any third party with whom an app shares
user data (in compliance with these Guidelines)—such as analytics tools,
advertising networks and third-party SDKs, as well as any parent, subsidiary
or other related entities that will have access to user data—will provide the
same or equal protection of user data as stated in the app's privacy policy
and required by these Guidelines. Explain its data retention/deletion
policies and describe how a user can revoke consent and/or request deletion
of the user's data."

(ii) Permission: "Apps that collect user or usage data must secure user
consent for the collection, even if such data is considered to be anonymous
at the time of or immediately following collection. Paid functionality must
not be dependent on or require a user to grant access to this data. Apps must
also provide the customer with an easily accessible and understandable way to
withdraw consent. Ensure your purpose strings clearly and completely describe
your use of the data."

(iii) Data Minimization: "Apps should only request access to data relevant to
the core functionality of the app and should only collect and use data that
is required to accomplish the relevant task."

(v) Account Sign-In: "If your app doesn't include significant account-based
features, let people use it without a login. ... Apps may not require users
to enter personal information to function, except when directly relevant to
the core functionality of the app or required by law."

(vi) "Developers that use their apps to surreptitiously discover passwords or
other private data will be removed from the Apple Developer Program."

(viii) "Apps that compile personal information from any source that is not
directly from the user or without the user's explicit consent, even public
databases, are not permitted on the App Store or alternative distribution."

**5.2.2 Third-Party Sites/Services**

"If your app uses, accesses, monetizes access to, or displays content from a
third-party service, ensure that you are specifically permitted to do so
under the service's terms of use. Authorization must be provided upon
request."

## What that means for each route [inferred]

- **Templates plus marked courses, on-device.** No new data collection: the
  student types their own courses into their own phone. 5.1.1 asks only that
  the privacy policy describe it (the bullet above). 5.2.2 applies to the
  requirement templates if they are read from Penn's `courses.upenn.edu`
  endpoints or Penn Labs' data: Smooth should be able to show that it is
  permitted, which is why the policy question to Penn Labs and ISC comes
  before Phase 2.
- **Canvas past courses.** Same trust model as today's Canvas reading; the
  review notes already describe it. No new consent beyond the existing
  Canvas sign-in, but the policy should say past courses are read.
- **Audit PDF import.** Data comes "directly from the user" (5.1.1 viii),
  stays on-device. Lowest App Store risk of the record routes.
- **Reading Path@Penn with the saved PennKey.** 5.2.2 is the live risk:
  Penn would have to permit it, and "authorization must be provided upon
  request". 5.1.1 (vi) is not triggered (the password is already captured
  with disclosure for Canvas; nothing is surreptitious), but the review
  notes and policy would need a new section, and the reviewer would see a
  second Penn system read with a stored password. Do not build without a
  written position from Penn.

# Coverage limits and exclusions

This release bundles **220 distinct Canvas sites** at US universities,
campuses and university systems. It prioritizes major national and public
universities and includes smaller regional institutions; it is not an exact
published “top 200” ranking. The complete list is [SCHOOLS.md](SCHOOLS.md).

## Schools using a different LMS

Do not treat an unrelated department or precollege program as campus-wide
Canvas support simply to include a famous name. Examples checked on
2026-10-27 and intentionally excluded from the bundled campus-wide list:

- Boston University: [Blackboard is the primary LMS](https://www.bu.edu/tech/services/teaching/lms/blackboard/).
- Michigan State University: [D2L Brightspace is the central LMS](https://help.d2l.msu.edu/d2l-docs). The Canvas directory has departmental MSU entries, which are not a general university sign-in.
- The retrieved Vanderbilt record is Vanderbilt University Medical Center,
  not evidence for campus-wide Vanderbilt Canvas.
- The retrieved Purdue records are professional programs and a high school,
  not evidence for campus-wide Purdue Canvas.
- The retrieved University of Rochester record is precollege, not evidence
  for campus-wide undergraduate Canvas.
- The retrieved University of Southern California record is `chanusc`, a
  program-specific hostname. It was not promoted to a university-wide entry.
- The retrieved Lehigh record is Vistex Institute, not campus-wide evidence.

The last five are evidence exclusions, not assertions about those schools'
current primary LMS. As of 2026-10-28 onboarding searches only the curated
catalog; specialized live-directory results are excluded. Missing schools
can still be connected by entering their Canvas address. Adding Blackboard/Brightspace/Moodle support
is a separate integration, not an additional Canvas URL.

## What the address checks establish

All 220 selected directory domains returned the Canvas `X-Canvas-Meta` HTTP
header during unauthenticated GET checks on 2026-10-27. We preserved only
host, response status and the presence of that header; no cookies, response
bodies, SSO parameters or credentials are committed. The nine previously
configured school identities and login routes remain stable, including
Cornell's gateway and Michigan's separate official-login/API origins. Known
original and directory host aliases resolve to one bundled entry.

These checks establish public Canvas addresses, not successful sign-in or
course/calendar sync. School SSO, MFA, WebKit restrictions, disabled calendar
feeds, API permissions and new cross-host redirects still need device testing.
Non-Penn backend features and PennKey credential storage remain Penn-only.
No Xcode, simulator or full app build was used for this catalog expansion.

## Shared systems and search

Rutgers, Indiana, Missouri, Nebraska and Wisconsin each have one result for
their shared Canvas site, with campus names retained as aliases. A separate
host (for example Michigan Ann Arbor, Dearborn and Flint) remains a separate
entry. Program and training listings from the live directory are not shown.

The local list works without a network lookup and ranks names and aliases
by relevance. Small spelling mistakes are tolerated when no direct match exists.
Actual Canvas login still requires internet. Existing manual URL entry stays
available for schools outside the list.

## Maintaining the catalog

The reviewed source is `schools.json`, containing each route, search aliases,
source directory record IDs and HTTP evidence. After reviewing updated
first-party evidence, run `python3 scripts/generate-canvas-catalog.py` to
regenerate Swift data and the human-readable list. Do not replace academic
sites with extension/precollege/catalog sites just because they share a name.

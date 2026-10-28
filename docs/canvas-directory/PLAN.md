# Bundled US Canvas catalog — 2026-10-27

2026-10-28 update: onboarding now searches only the 220 curated sites,
ranked by name/alias relevance with bounded typo tolerance. Live results
were removed to exclude extension, online-learning and training entries.
Manual Canvas address entry remains. The 18 focused tests pass; a Terminal
device build is used for phone review without opening Xcode UI or simulator.

The requested expansion is a substantial local catalog, not just live lookup.
Target: approximately 200 distinct Canvas sites at major US universities,
prioritizing nationally prominent universities and large public institutions.
This is a curated coverage list, not a reproduction of a published ranking.

Use Instructure's first-party directory as address evidence. Preserve existing
Penn/Cornell identities and Michigan's verified login-to-API origin mapping.
Exclude school departments, extension-only systems, catalogs, K–12, overseas
institutions and ambiguous matches from campus-wide entries. Some prominent
universities use Blackboard, Brightspace or Moodle; do not create false Canvas
routes for them. Record exclusions and limitations separately.

Bundle names, search aliases, origins, login paths and source evidence. Local
matches must appear even if the directory is unavailable. Normalize known
aliases before deduplicating remote results. Check public redirects without
credentials to identify different Canvas/API hosts, without attempting SSO.

Validate count/unique identity, safe HTTPS addresses, representative major
schools, alias search and regression fixtures with lightweight isolated tests.
Do not open Xcode or simulator. A confirmed public Canvas address is not an
end-to-end authenticated Smooth integration test.

## Completed

- 220 distinct sites bundled with names, acronyms, campus aliases and login
  routes. All selected directory domains returned Canvas HTTP headers.
- Source evidence saved in schools.json; generated Swift data and the full
  list can be regenerated offline with scripts/generate-canvas-catalog.py.
- 16 focused tests in 2 suites passed, including 22 representative search
  cases, shared-site deduplication, stable aliases and HTTPS validation.
- The school view passed syntax parsing. No full app build, Xcode or simulator
  run. Authenticated integration testing remains outstanding.

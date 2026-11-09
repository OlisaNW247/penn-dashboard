# Degree-progress research: source notes (2026-11-09)

The report is `docs/DEGREE_PROGRESS_RESEARCH_2026-11-09.md`. These notes are
its evidence, one file per area, each with labelled findings, a source list,
the hosts that were blocked, and open questions. Notes 01 to 08 were written
by parallel researcher agents and checked by the synthesising session, which
re-read the Penn Labs source files behind the surprising claims (the public
`courses.upenn.edu` endpoints, the Degree Works XML parser, the beta-gated
API, the old Degree Works client) before repeating them. Notes 04 and 09 were
written by the synthesising session.

| Note | Area |
|---|---|
| `01-path-at-penn.md` | What Path@Penn offers students; the product; sign-in; export |
| `02-public-data-penn-labs.md` | Catalog, Penn Labs API, Penn Degree Plan's data source and rule model |
| `03-data-routes-and-policy.md` | Routes A-D for the student's record; Penn policies; FERPA |
| `04-privacy-and-app-store.md` | What stays on-device; PRIVACY.md draft; Apple 5.1.1 and 5.2.2 quoted |
| `05-modelling-requirements.md` | Scribe, PeopleSoft, Penn Labs, open planners; recommended rule shape |
| `06-beyond-penn.md` | Degree Works and Stellic market; peer schools; portability |
| `07-product-pain-points.md` | Student complaints; Penn Degree Plan's UI; conventions; calendar |
| `08-code-seams.md` | Where it plugs into this repo, with `path:line` references |
| `09-rules-engine-sketch.md` | A Python sketch of the engine and planner, with its output |

## Labels

- **[read directly]**: the page or source file was fetched and read.
- **[search summary only]**: only a search engine's summary of the page was
  available, because the host was blocked from the container.
- **[inferred]**: reasoning from the above.

## Network in the research container

The default cloud environment refused connections (403 on CONNECT, logged in
the proxy status) to every `*.upenn.edu` host, `penncoursereview.com`,
`penncourseplan.com`, `pennlabs.org`, `reddit.com`, `thedp.com`,
`stellic.com`, `ellucian.com`, `web.archive.org`, `canvas.instructure.com`,
`ed.gov`, `arxiv.org` and most vendor documentation hosts. Reachable:
`github.com`, `raw.githubusercontent.com`, `developer.apple.com`, and web
search summaries. A personal cloud environment named `penn-dashboard` was
created on 2026-11-09 with sixteen of those hosts allowed (Penn, Penn Labs,
the DP, Stellic, Ellucian); the running session could not move onto it, so
nothing in these notes used it. Start the next research session on that
environment to read the Penn pages directly.

## Rules followed

No sign-in to any system. No student data fetched. No real course history,
ids, names, cookies or tokens in these files. Penn Labs' code was read from
its public repository; its live endpoints were not called.

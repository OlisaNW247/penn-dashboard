# Agent audit, 2026-11-24: source notes

Notes behind `docs/AGENT_AUDIT_2026-11-24.md`. Read the report first.

- `security-review.md`: a read-only review of the agent connection's code on
  `origin/v13` (backend functions, migrations, connector front, phone).
  Findings with file:line and severity. Findings 1, 3 and 5 were re-checked in
  the source for the report.
- `apple-canvas-penn-policy.md`: Apple's App Review Guidelines (5.1.1,
  5.1.2(i), 5.2.2, 4.7), Instructure's API policy and statements on outside
  agents, Penn's guidance on AI and academic integrity, and press on agents
  completing Canvas work. Penn's Code of Academic Integrity page answered 403
  and was not read directly.
- `ai-accounts-and-directories.md`: the four ways a student's own AI account
  could meet Smooth (their subscription inside Smooth, a connector, their own
  API key, platform routes with no account), plus the connector-directory
  rules and the AI vendors' usage policies on academic dishonesty. The three
  vendor quotes the report relies on were re-read on the live pages on
  2026-11-24.

Live checks, all read-only and without credentials, 2026-11-24 about 04:07 UTC:
Apple's public lookup for app 6783911002 (3.5.0, released 2026-11-23
20:59:10 UTC); the connector front's OAuth discovery document (200); an
unsigned POST to `/functions/v1/mcp` (401 with a bearer challenge); the
`update-manifest` branch (floor 3.4.1). No Supabase management token was on
the machine, so function versions come from the project's notes.

Added later on 2026-11-24, for Part 3 of the report (which parts of Smooth a
student's own AI could power):

- `personal-claude-anthropic-routes.md`: sign-in programmes, Claude Platform
  OAuth linked billing, MCP Apps, write-back rules, the Claude iPhone app's
  Shortcuts action, scheduled tasks, plan API credits, App Attest.
- `personal-ai-apple-routes.md`: iOS 27 Extensions (unconfirmed), Foundation
  Models and provider packages, App Intents and Siri, Shortcuts, share sheet.
- `personal-ai-other-providers.md`: ChatGPT plan usage and custom connectors,
  Gemini, other consumer AIs, user-pays brokers. Several lines there rest on
  secondary sources and are marked so.

The linked-billing, interactive-connector and scheduled-task quotes were
re-read on the live pages for the report.

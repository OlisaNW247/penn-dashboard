# Personal Claude account routes for Smooth: PARTIAL research (2026-11-24)

STATUS: Items A-G completed in a second session on 2026-11-24 (section 3). Section 2 iOS note superseded by 3A.

## 1. Sign in with Claude / OAuth for third parties: NO sanctioned program found
Source: https://code.claude.com/docs/en/legal-and-compliance (read 2026-11-24; page undated, current)
- "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users."
- "developers may not collect, store, or intermediate Claude.ai credentials or session tokens"
- Developers (incl. Agent SDK users) "should use API key authentication through Claude Console or a supported cloud provider."
- Only exception wording: end user may sign in to the UNMODIFIED Claude Code binary with their own subscription, including where a platform hosts Claude Code. Not a partner list. Contact sales is the stated route for "permitted authentication methods for your use case".
- Agent SDK overview note (https://code.claude.com/docs/en/agent-sdk/overview, read 2026-11-24): "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products" -> "unless previously approved" implies case-by-case approvals exist, via sales. No public partner list or roadmap found (search was unavailable).

## 2. MCP Apps (interactive UI in chat): YES on Claude web/desktop; iOS UNCONFIRMED
Source: https://modelcontextprotocol.io/extensions/apps/overview (read 2026-11-24)
- "MCP Apps let servers return interactive HTML interfaces (data visualizations, forms, dashboards) that render directly in the chat."
- "MCP Apps are currently supported by Claude, Claude Desktop, VS Code GitHub Copilot, Microsoft 365 Copilot, Goose, Postman..." (client matrix: https://modelcontextprotocol.io/extensions/client-matrix.md - not read).
- Sandboxed iframe; app can call server tools back ("Your app can call any tool on the MCP server"). Spec: https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx ; docs https://apps.extensions.modelcontextprotocol.io
- NOT verified: Claude iOS rendering, plan requirements, directory rules.

## 3. Completed pass (2026-11-24, second session; WebFetch/WebSearch worked, no hosts blocked)

### A. MCP Apps in Claude (iOS, plans, custom connectors)
- Client matrix (https://modelcontextprotocol.io/extensions/client-matrix.md): rows exist for "Claude (web)", "Claude Desktop", "Claude Code"; the converted page lost its check marks, so iOS is NOT confirmed by the matrix (it has no iOS row).
- Anthropic says it does render on mobile. https://claude.com/docs/connectors/building/mcp-apps/design-guidelines.md : "On mobile, Claude renders apps in a native WebView, `WKWebView` on iOS". Inline cards render "full-width within the conversation"; fullscreen "fills the entire screen". Camera/mic available on iOS if the user allows.
- https://support.claude.com/en/articles/13454812-use-interactive-connectors-in-claude : "Interactive connectors are available for all users on Claude, Cowork, Claude Desktop, and Claude for iOS/Android." Side panel, full-site views and pinning are web/Desktop only and need the new unified experience ("They aren't available on Claude Mobile yet").
- Plan: no plan requirement stated for basic inline apps. Side panel, entry points, app tools, embedded sites in custom connectors "aren't available in every organization" (https://claude.com/docs/connectors/building/mcp-apps/getting-started.md).
- Custom vs directory: custom connectors (Free gets one; Pro/Max/Ultra unlimited per https://claude.com/docs/connectors/custom/add-unlisted.md) can show MCP Apps; Claude may mark a custom connector's open app "Unverified" (https://claude.com/docs/connectors/verification.md). Entry points work for Verified and custom, not Community. Embedded websites need Verified in the directory.
- Limits that matter for Smooth: inline cards max 2 actions, no nested scroll, vertical pan goes to the chat; app reloads from your HTML so state must live on your server. Design for tasks "the user can finish inside the conversation".
- Caveat: the iOS statement for custom (unlisted) connectors specifically is inferred (custom connectors use the same technology per verification page); not tested on a device.

### B. Write-back and directory rules
- https://claude.com/docs/connectors/building/review-criteria.md (undated): split read and write tools ("A single tool that accepts both safe HTTP methods... is rejected"); every tool needs title plus `readOnlyHint` / `destructiveHint`; "Claude can use these hints to decide when to ask the user for confirmation. Read-only tools can run without per-call confirmation, and destructive tools can require it."; don't "Query Claude's memory, chat history, conversation summaries, or user files"; no collecting conversation data beyond need; call your own first-party APIs; not accepted: money transfer, AI image/video/audio generation.
- Directory policy https://support.claude.com/en/articles/13145358-anthropic-software-directory-policy : no general write-confirmation rule; tools must not push Claude to call other software "unless requested and intended by a user" (2D); privacy policy required (3A).
- Verdict: Claude writing a plan, reminders, summaries or flashcards back into Smooth via an annotated write tool is allowed; the app then shows what is stored. Custom connectors are not subject to review at all. Student sees per-tool permission (Always allow / Needs approval / Blocked).

### C. Claude iOS integration points
- App Intents: https://support.claude.com/en/articles/10263469-using-claude-app-intents-shortcuts-and-widgets-on-ios : "Ask Claude" intent works from Spotlight, Siri, Share menu, any app supporting intents, and as a Shortcuts step; chainable; iOS 18+; uses default model; counts toward usage limit. Response format to Shortcuts not described. Also widget (new chat, dictation, photo) and "Analyze Photo with Claude" control.
- So a Smooth Shortcut or app could invoke the student's Claude with text (their plan pays), but Smooth cannot call it directly in-app; the student runs it. Output hand-back unverified.
- URL scheme: https://support.claude.com/en/articles/14898120-open-the-claude-mobile-app-with-a-link documents only `claude://code/new?q=` (Claude Code tab; needs Claude Code access; "All parameter values must be URL-encoded"), plus `https://claude.ai/code/...` universal links. No documented chat prefill for mobile. Search snippet says desktop doc https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link documents `claude://claude.ai/new?q=` (prefill, ~14,000 char cap) but I did not read that page; `https://claude.ai/new?q=` is only reported by third parties and one GitHub issue says it broke. Treat as untested on iOS.
- No Siri/Apple Intelligence extension found beyond the Siri-invoked App Intent.

### D. Scheduled / background work with connectors
- https://support.claude.com/en/articles/13854387-schedule-recurring-tasks-in-claude-cowork.md : scheduled tasks on "all paid plans (Pro, Max, Ultra, Team, Enterprise)", not Free. Cadence hourly/daily/weekly/weekdays/manual. "Scheduled tasks run remotely" even with computer asleep (unless a local folder is chosen). Tasks "can use the same connectors, skills, and plugins". A connector tool set to "Always ask" may wait or be skipped, so the Smooth write tool needs Always allow. Creation: from any conversation in the new experience; mobile creation not stated; runs are reviewable on any surface. No run caps stated (a third-party article cites per-day limits for Claude Code routines, unverified).
- Verdict: yes in principle: a Pro+ student connects Smooth, schedules "each morning read my new announcements via Smooth and save a summary", and the write tool stores it for the app. Needs the paid plan and the connector reachable by Anthropic's servers (OAuth).

### E. API credits and BYO key
- https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers : Max $100/mo, Ultra $200/mo, Team $20 or $100 per seat (pool cap $500). "Free, Pro, and Enterprise plans aren't eligible." Covers API, Managed Agents, Agent SDK; not Claude Code or extra usage; expire each cycle; claimed by linking a Console org (program terms https://www.anthropic.com/legal/credit-terms, not read). Plan-bought-via-app-store eligible. Reported start date 2026-10-07 not confirmed on page.
- SURPRISE: https://platform.claude.com/docs/en/manage-claude/oauth-apps/organization-billing-connections : those monthly plan credits "can't pay for these requests" under Linked billing; only credit bought in Console counts.
- BYO Console key: Commercial Terms https://www.anthropic.com/legal/commercial-terms say customer "is responsible for fees incurred by its account" and is liable for activity under its keys; no explicit rule permitting or forbidding pasting a key into a third-party app; only a ban on reselling the Services. The login help page https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account calls an API key "the preferred way" to use third-party software. So pasting one's own key is the sanctioned pattern in practice, but a Keychain-stored key on a college student is a poor product (needs Console account and prepaid credit).

### F. App Attest and ClaudeForFoundationModels
- https://platform.claude.com/docs/en/manage-claude/app-attest : "with usage billed to your workspace"; tokens "carry no end-user identity", expire in 1 hour, Messages API only. Developer-billed only; no student sign-in. Needs physical device, admin role, Team ID.
- https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models : package is in beta, "requires the OS 27 betas", iOS 27+/Xcode 27; "Usage is billed to your Anthropic account at standard API pricing". Auth modes: appAttest, proxied, apiKey. No pricing premium. Not a route for student plans; it would only replace Smooth's own backend proxy (cost stays with Smooth).

### G. "Unless previously approved" and approval route
- No public application form or partner page found. The legal page says contact sales. No named third-party product with Claude.ai login found.
- BUT two official alternatives exist: (1) Claude Platform OAuth / Linked billing (beta, https://platform.claude.com/docs/en/manage-claude/oauth-apps/overview): user signs in to Claude and approves the app so their Claude organization pays for API requests. Requires: user has Admin/Billing role in a Console org that pays Anthropic directly with Console-bought credit (subscription-only users refused 403 `user_profile_not_billable`); the developer needs a back end with Workload Identity Federation, domain proof and Anthropic review ("Not approved" is possible); redirect on developer's domain. Native-app use not addressed. (Only first 100,000 of 121,428 chars of the linked billing page read.) (2) https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account : "Anthropic may, at its discretion, let paid subscribers with usage credits enabled use certain third-party tools", billed to the subscriber's usage credits. Discretionary, no application path found.
- Directory/MCP review contact seen in search snippet: mcp-review@anthropic.com (unverified); MCP Apps feedback: mcp-apps@anthropic.com (read on getting-started page).

## 8. Agent SDK with a user's own plan
- Legal page: "Advertised usage limits for Pro, Max, and Ultra plans assume ordinary, individual usage of Claude Code and the Agent SDK." Developers building products should use API keys. Agent SDK is under Commercial Terms even for end-user products.
- Implication: user's own local use on their plan is tolerated; shipping an app that uses a student's plan is not.

## Surprises
- Legal page names an "Ultra" plan explicitly.
- Legal page lets "customers" host the UNMODIFIED Claude Code binary where each end user signs in with their own subscription or API key. A hosted-Claude-Code-per-student model is the only plan-credential path with explicit text, but is far from an iPhone app feature.

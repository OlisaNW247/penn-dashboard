# Agent platform surfaces for third-party apps (ChatGPT, Claude, Muse, Apple Intelligence), as of October 2026

Research date 2026-10-30. Many 2026 product details come only from secondary press; each such claim is flagged. Vendor help pages that returned 403/404 to the fetcher (help.openai.com ChatGPT Work page, openai.com usage-policies, OpenAI developer-mode doc) were NOT read directly; only search-result summaries of them were available.

## 1. What do the products named in the brief actually refer to (ChatGPT agent/Operator/Atlas/Work/dots, Claude Duet, Muse)?

### Takeaway
All three disputed names are real as of Oct 2026, but "ChatGPT dot" is almost certainly OpenAI's "dots" (always-on personal agents, 2026-09-29), "Claude Duet" is Anthropic's proactive agent (2026-10-21 research preview), and "Muse" is most plausibly Meta's Muse (2026-09-08). The older OpenAI browser agents (Operator, agent mode, Atlas) have been retired, so most 2025 write-ups about them are out of date.

### Cited Findings
- OpenAI's help page now says ChatGPT agent is no longer available and points to ChatGPT Work (search-result summary of the help page; page itself returned 403) — [OpenAI help](https://help.openai.com/en/articles/11752874-chatgpt-agent)
- ChatGPT Work was announced 2026-07-09 on GPT-5.6; Atlas stops working 2026-08-09; agentic browsing moved into the ChatGPT desktop app, a Chrome extension/sidebar, and a remote cloud browser (secondary press) — [Pulse 2.0](https://pulse2.com/openai-introduces-chatgpt-work-and-deprecates-atlas-browser), [PPC Land](https://ppc.land/openai-kills-atlas-browser-folds-it-into-new-chatgpt-work-agent/), [Pasquale Pillitteri](https://pasqualepillitteri.it/en/news/7783/openai-shuts-down-atlas-agentic-features-move-to)
- Operator was folded into agent mode and then removed; its site is no longer accessible (third-party guide) — [Carly](https://www.usecarly.com/blog/what-is-chatgpt-agent/)
- "dots": always-on personal agents in ChatGPT launched 2026-09-29 at DevDay; each has its own cloud computer and browser, connects to 4,000+ apps; starts with Pro and Business Premium in eligible markets (not EEA/Switzerland/UK), Enterprise/Edu/Healthcare beta; secondary press — [Al Jazeera](https://www.aljazeera.com/economy/2026/9/30/openai-launches-dots-personal-ai-assistant-built-to-handle-everything), [TechCrunch](https://techcrunch.com/2026/09/29/openai-launches-dots-its-bubbly-agentic-avatar/), [AI Weekly](https://aiweekly.co/alerts/openai-launches-dots-always-on-chatgpt-agents-at-devday)
- "ChatGPT Dot" by that exact name: no result found. OpenAI's separate hardware device (with Jony Ive's io) was still unreleased per mid-2026 reports, form factor speculative — [Android Authority](https://www.androidauthority.com/openai-device-launch-2026-3633803), [TechRadar](https://www.techradar.com/ai-platforms-assistants/openai/openais-mysterious-chatgpt-gadget-could-take-the-form-of-an-ai-powered-pen)
- Claude Duet: research preview launched 2026-10-21; US Pro/Max waitlist; iOS, Android, web; runs on Claude Opus 5.5; works in background across connected accounts (secondary press) — [Let's Data Science](https://letsdatascience.com/news/anthropic-opens-claude-duet-research-preview-for-proactive-a-16522f5d), [Siecle Digital](https://siecledigital.fr/2026/10/22/avec-claude-duet-anthropic-veut-concurrencer-meta-muse-et-openai-dots/)
- Muse (Meta): personal agent launched 2026-09-08 in US; iOS/Android app, muse.ai, and WhatsApp; powered by "Muse Spark" model; "open a browser, fill out forms, and negotiate"; runs on "a dedicated, secure virtual machine" — [PBS NewsHour](https://www.pbs.org/newshour/nation/meta-launches-personal-ai-agent-muse-to-help-with-everyday-tasks), [Relevant Audience](https://www.relevantaudience.com/ai/meta-muse-personal-ai-agent-launch/)
- Other "Muse" products exist (not investigated: e.g., older Muse AI-writing/music tools; Muse Spark is Meta's model name). I did not identify a different agent product named Muse in searches; ambiguity remains untested beyond Meta's.

### Inferences
- The owner's "Muse / Claude Duet / ChatGPT dot" trio matches Meta Muse / Anthropic Duet / OpenAI dots, which all launched within about six weeks (Sept 8 to Oct 21, 2026) as cloud-VM, always-on agents. That is the most likely meaning.

### Gaps
- No primary OpenAI/Anthropic/Meta announcement page was read for dots, Duet or Muse; all rely on press. Pricing figures conflict across outlets and are omitted.

## 2. Integration mechanisms for third-party apps; MCP auth spec; who can add a connector

### Takeaway
MCP remote servers are the common denominator: ChatGPT (as "plugins"/apps, formerly Apps SDK) and Claude (custom connectors) both consume them, and the current MCP spec requires OAuth 2.1-style auth with RFC 9728 discovery and RFC 8707 resource indicators. Consumer plans can add custom connectors on Claude (even Free, limited to one); ChatGPT custom MCP apps are gated behind developer mode on paid plans.

### Cited Findings
- MCP authorization is OPTIONAL; for HTTP transports servers SHOULD conform. MCP server = OAuth 2.1 resource server; MUST implement RFC 9728 Protected Resource Metadata; clients MUST use it for AS discovery; clients MUST send RFC 8707 `resource` on both authorize and token requests; PKCE used; tokens in Authorization header, never query string; servers MUST validate audience and MUST NOT accept or transit other tokens — [MCP spec (draft)](https://modelcontextprotocol.io/specification/draft/basic/authorization)
- Client registration: Client ID Metadata Documents (CIMD) SHOULD be supported; Dynamic Client Registration is MAY and "deprecated and retained for backwards compatibility"; pre-registration also allowed — same source. RFC 9207 `iss` validation also in the draft.
- Scope step-up: server returns 403 `insufficient_scope` with `WWW-Authenticate` scope; clients SHOULD re-authorize with union of scopes — same source.
- Spec text read is the "draft" page; I did not confirm which dated release first carried the CIMD/DCR-deprecation wording (secondary blogs say 2026-07-28; unverified).
- Claude custom connectors via remote MCP: Free (one connector), Pro, Max, Team, Enterprise. Pro/Max add under Customize > Connectors > Add custom connector with name and URL; Team/Enterprise: an Owner adds under Organization settings > Connectors, then each member connects. OAuth options: "Use Claude's published identity", "Register automatically", "Use your own OAuth client"; fixed API key/bearer token can go in Request headers. Connections originate from Anthropic's cloud, so the server must be publicly reachable — [Claude Help: custom connectors](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp)
- ChatGPT developer mode: full MCP client access on web for Pro, Plus, Business, Enterprise, Education; enable under Settings > Security and login; SSE and streaming HTTP; auth OAuth, none or mixed; static credentials used if provided, otherwise CIMD when the AS advertises it (search-result summary; page 404'd) — [OpenAI developer mode](https://developers.openai.com/api/docs/guides/developer-mode/index.html); beta help article [OpenAI Help 12584461](https://help.openai.com/mt-mt/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt)
- OpenAI's docs for ChatGPT apps now live under "Plugins": plugins combine skills, MCP servers and optional UI; remote MCP servers go through directory review — [OpenAI plugins docs](https://developers.openai.com/apps-sdk). The Apps SDK to plugins rename is confirmed only by this docs index and a third-party migration note.
- OpenAI plugin MCP guidance: use OAuth 2.1 when user auth is needed; enforce authorization in the server on every request; private servers can use OpenAI-managed mTLS; UI is optional and returned from selected tools — [OpenAI: build an MCP server](https://developers.openai.com/plugins/build/mcp-server)
- ChatGPT Work plugin directory: 1,400+ plugins (press) — [Digital Applied](https://digitalapplied.com/blog/chatgpt-work-openai-agent-launch-2026)
- Claude Duet reportedly uses "more than 6,000 connectors and plugins"; unclear whether it takes custom MCP servers — [HackerNoon](https://hackernoon.com/what-is-claude-duet-inside-anthropics-always-on-ai-assistant)
- Muse: Meta opened "Muse Connectors" to developers in Sept 2026 (curated; reports conflict on whether a submission portal exists); consumer Muse reportedly has no custom-MCP setting, Muse Code does; Zapier connector gives MCP-backed access to many apps (vendor/secondary) — [Skills Playground](https://skillsplayground.com/integrations/muse/), [Parallel](https://parallel.ai/articles/meta-muse-custom-integrations), [Zapier](https://zapier.com/blog/zapier-connector-in-muse.md), [RuntimeWire](https://runtimewire.com/article/meta-opens-muse-connectors-developers)

### Inferences
- A Smooth remote MCP server (public HTTPS, OAuth with RFC 9728 metadata, PKCE, audience-bound tokens) would work in both Claude (any plan) and ChatGPT (developer mode, then directory review for general users).
- Smooth's anonymous-account backend (Supabase) is the natural OAuth AS; but today only Penn installs use the backend, and Smooth's privacy posture says assignments never leave the phone. Exposing "list my assignments" via MCP would require either uploading the list (a privacy change that must be reflected in docs/PRIVACY.md) or a device-side mechanism.

### Gaps
- Exact OpenAI approval rules for connector tool calls in dots/Work; OpenAI plugin directory plan eligibility for end users; whether Claude Duet accepts custom MCP.

## 3. What each agent can DO in a browser, and how it authenticates to third-party sites

### Takeaway
No platform offers a developer-facing way to inject cookies or a session. Agents either use the user's own signed-in Chrome (Claude in Chrome), a cloud browser where the user logs in themselves via a handoff (OpenAI agent mode, now retired; cloud browser/dots), or a vendor VM whose login handling is not documented (Duet, Muse).

### Cited Findings
- Claude in Chrome: paid plans (Pro, Max, Team, Enterprise); side panel defaults to "Automatically approve" mode, pausing when approval needed; can switch to manual approval; admins can set site allow/blocklists — [Claude Help: getting started](https://support.anthropic.com/en/articles/12012173-getting-started-with-claude-for-chrome)
- It acts "directly [on] websites on your behalf" and Anthropic advises "a separate browser profile without access to sensitive accounts"; 1Password can handle sign-ins so passwords stay out of Claude's context — [Claude Help: safety](https://support.claude.com/en/articles/12902428). Neither page states in so many words that it uses the existing signed-in profile; the advice strongly implies it works in the user's own Chrome (inference).
- Per-site permission prompts: "Allow this action", "Always allow actions on this site", "Decline"; even with Always allow, still asks before purchases, permanent deletion, permission changes, account creation (search-result summary of the help guide, not fully confirmed on the fetched page) — [Claude Help](https://support.anthropic.com/en/articles/12012173-getting-started-with-claude-for-chrome)
- Claude in Chrome blocks adult and pirated sites; prohibited from stock trading, bypassing captchas, inputting sensitive data; confirmations for downloads and entering sensitive info; Anthropic claims <0.08% prompt-injection attack success in internal testing — [Claude Help: safety](https://support.claude.com/en/articles/12902428)
- Claude API computer use: screenshot/mouse/keyboard toolset (`computer_toolset_20260801`), run in your own sandbox/VM; docs warn against giving it account logins, advise allowlisted domains, and "Ask a human to confirm" decisions with real-world consequences such as financial transactions or agreeing to terms — [Anthropic computer use docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool). The developer controls the environment, so a developer could preload a browser profile, but that is the developer's own machine, not the end user's.
- Claude Duet: each user gets a cloud VM with its own browser; "never directly sees your passwords or sign-in tokens"; purchases via Stripe Link virtual card; login mechanics not explained; approval tiers: read/draft automatic; send/pay/sign/delete need approval; securities trading and moving money between accounts blocked even if approved; same usage limits as rest of Claude — [HackerNoon](https://hackernoon.com/what-is-claude-duet-inside-anthropics-always-on-ai-assistant) (secondary), [Inside](https://www.inside.com.tw/article/42702-anthropic-claude-duet-proactive-ai-agent)
- OpenAI agent mode (retired): virtual browser on a remote machine; when a login was needed it asked the user to take over via the "…" menu; screenshots paused while the user typed; limits 40 msgs/month Plus, 400 Pro — [Carly](https://www.usecarly.com/blog/what-is-chatgpt-agent/); safeguards included confirmations for high-impact actions, prompt-injection monitoring, and "watch mode" on some sites (search summary of help page) — [OpenAI help](https://help.openai.com/en/articles/11752874-chatgpt-agent). OpenAI also advised signing out and clearing cookies since sessions persist.
- ChatGPT Work: desktop app has a built-in multi-tab browser the agent can drive, plus Computer Use; updated Chrome sidebar extension; Plan mode for approval; "advanced models review important actions involving connected tools and APIs"; same usage structure as Codex; sign-in handling not described on the page read — [Digital Applied](https://digitalapplied.com/blog/chatgpt-work-openai-agent-launch-2026). Desktop app can "sign into accounts, download files" (secondary) — [Pasquale Pillitteri](https://pasqualepillitteri.it/en/news/7783/openai-shuts-down-atlas-agentic-features-move-to). Third-party guide says the secure handoff is the capability users miss most in Work — [Carly](https://www.usecarly.com/blog/what-is-chatgpt-agent/)
- dots: own cloud computer and browser, kept separate from the user's computer unless the user connects them (press) — [AI Weekly](https://aiweekly.co/alerts/openai-launches-dots-always-on-chatgpt-agents-at-devday)
- Muse: can open a browser, fill forms, check out; reportedly drives Chromium on a cloud VM for sites without APIs; login/approval behavior not described in sources — [PBS](https://www.pbs.org/newshour/nation/meta-launches-personal-ai-agent-muse-to-help-with-everyday-tasks), [Parallel](https://parallel.ai/articles/meta-muse-custom-integrations)
- Claude Code with browser tools: not separately researched; this session's own tooling shows Claude Code can drive Chrome via the Claude-in-Chrome extension (local observation, no URL).

### Inferences
- A developer "cookie jar handoff" is not a documented feature anywhere. For Smooth, the only path where the student's saved Canvas session is effective is the student's own Chrome profile (Claude in Chrome), where the student is already signed in to Canvas (and Penn SSO/Duo is the student's own). Smooth's cookies live in the iPhone Keychain, device-bound; they cannot reach a cloud agent without breaking the "cookies never leave the phone" posture, and Canvas cookies sent to a vendor VM would also be a bearer credential.
- Cloud-VM agents (Duet, dots, Muse) would hit PennKey + Duo and need a human takeover; takeover UX for Duet/dots/Muse is undocumented.

### Gaps
- No primary doc for Duet/dots/Muse login handoff. Whether Chrome extension for ChatGPT uses the user's signed-in profile is not confirmed. No source documented captcha/Duo behavior for any agent.

## 4. Rate limits, approval prompts, policy restrictions relevant to submitting coursework

### Takeaway
No agent-specific refusal rule about submitting coursework was found. Both vendors' usage policies mention academic dishonesty or unattributed AI work in general terms, and all agents require confirmation on consequential actions; submitting an assignment would plausibly hit those prompts and policy lines, and universities' own integrity rules decide the rest.

### Cited Findings
- Anthropic AUP, under fraudulent/abusive practices: "Plagiarize or submit AI-assisted work without proper permission or attribution" — [Anthropic AUP](https://www.anthropic.com/legal/aup). Also bars impersonating individuals and bypassing authentication; "Agentic use cases must comply with the Usage Policy."
- OpenAI usage policies list "academic dishonesty" among prohibited uses (quoted via search summary; page itself 403): "any use for: academic dishonesty, deceit, fraud, scams, spam, or impersonation"; a later version is shown as effective 2026-11-20 and its wording was not checked — [OpenAI usage policies](https://openai.com/policies/usage-policies/)
- Claude in Chrome: action confirmations for high-risk actions; "act without asking"/auto-approve modes exist; Claude asks before downloads and sensitive input — [Claude Help](https://support.claude.com/en/articles/12902428)
- Claude connector tool calls: Claude asks approval before invoking tools; "Allow always" available; in Research mode connector tools may run without further approval, so Anthropic recommends disabling write tools — [Claude Help: custom connectors](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp)
- OpenAI MCP tool annotations (readOnlyHint, destructiveHint, openWorldHint) "help ChatGPT and Codex choose appropriate confirmation"; servers should "Require confirmation for consequential write actions" — [OpenAI: build an MCP server](https://developers.openai.com/plugins/build/mcp-server)
- Limits: agent mode (retired) 40/month Plus; ChatGPT Work uses Codex-style plan usage with no published hard numbers; Duet shares Claude plan limits and polls accounts every few hours; MCP server rate limits are the server's own — sources above.
- Institutions: universities state course policy governs AI use (e.g., [Columbia CUIT](https://www.cuit.columbia.edu/content/claude-education)).

### Inferences
- Because "turn it in" is a consequential, irreversible action, expect an approval prompt on every platform. Whether a model refuses to do the assignment itself depends on context and is not specified by policy text; the policy lines above create exposure for Smooth if marketed as "agent does and submits your homework".
- Canvas itself and Penn's academic integrity code (not researched) are separate constraints; Canvas may also rate-limit and Smooth's Penn restrictions on student API tokens (CLAUDE.md) mean the personal-access-token path used by community servers is not available to Penn students.

### Gaps
- Direct text of OpenAI's current policy page (403) and its Nov 2026 revision; no agent-product-specific academic-integrity refusal behavior documented; no Canvas/Instructure policy on automated agents researched.

## 5. iOS: App Intents, Apple Intelligence, Siri, Shortcuts

### Takeaway
App Intents is the supported way for Siri/Shortcuts/Spotlight to read Smooth's assignment list on-device and to trigger Smooth actions; there is no documented iOS agent surface that drives a web page inside another app.

### Cited Findings
- WWDC26 session 240: Siri in "the 27 releases" can access an app's entities, act through its intents, and understand on-screen context; App Intents are "the foundation"; App Schemas are a specialization that Siri knows how to process; domains cover mail, photos, messages etc.; `IndexedEntity` for semantic search, `EntityStringQuery` as fallback; on-screen awareness via `NSUserActivity` or view annotations; content passes between apps via `Transferable`; the page said APIs are "available today" but gave no minimum OS or region — [Apple WWDC26 240](https://developer.apple.com/videos/play/wwdc2026/240/)
- Web page driving by Siri: not covered in that session.
- A developer forum thread reports Siri read on-screen values but could not reach data on other tabs via the entity query (single anecdote) — [Apple forums](https://developer.apple.com/forums/thread/837249)
- 2024 session: App Intents also surfaced in Shortcuts and Spotlight; Siri on-screen awareness was originally tied to iOS 18-era domains — [WWDC24 10133](https://developer.apple.com/videos/play/wwdc2024/10133/?time=59)

### Inferences
- Smooth could expose `AssignmentEntity` (title, course, due date, Canvas URL) and intents such as "next due" or "open assignment" with data staying on-device, consistent with its privacy posture. An intent that opens the Canvas URL in Smooth's own WKWebView session could act "as the student" using the on-device cookie jar, but nothing on iOS lets Siri fill and submit a Canvas form autonomously; Smooth would have to implement any form automation itself.
- Which OS version the schema/Siri features need (iOS 26 vs 27) was not confirmed.

### Gaps
- Minimum OS, Apple Intelligence device and region requirements; whether Siri can chain a third-party intent with a web action.

## 6. Existing Canvas MCP servers and connectors

### Takeaway
Many unofficial, community Canvas MCP servers exist, all using the student's Canvas personal access token plus base URL; no official Instructure public MCP server for outside agents was found.

### Cited Findings
- plyght/canvas-mcp (TypeScript): `CANVAS_BASE_URL` and `CANVAS_ACCESS_TOKEN` env vars, Bearer auth — [LobeHub listing](https://lobehub.com/mcp/plyght-canvas-mcp)
- admin978/canvas-mcp (Python, alpha, MIT; PyPI canvas-local-mcp): token in `~/.canvas.env` chmod 600; token generated at Account > Settings > Approved Integrations > + New Access Token — [GitHub](https://github.com/admin978/canvas-mcp), [PyPI](https://pypi.org/project/canvas-local-mcp/0.1.0/)
- mandaza/mcp-canvas-lms-student (Node) uses the same token + URL pattern (search-result summary). Others listed: vishalsachdev/canvas-mcp, brendan-ch/canvas-mcp, evanap003300/canvas-mcp — [Glama](https://glama.ai/mcp/servers/@vishalsachdev/canvas-mcp/blob/f29d84fdffa1043c1d4cef2afee3ad900cd8dee9/.claude/plans/future-proofing-adoption.md), [Glama](https://glama.ai/mcp/servers/evanap003300/canvas-mcp)
- One commercial blog says Instructure has not shipped a public Canvas MCP server for outside agents; IgniteAI's MCP use is internal; an official Claude LTI exists for Claude for Education (installed by an admin) — [Carly](https://www.usecarly.com/blog/claude-canvas-lms-integration/) (vendor blog; unverified against Instructure)

### Inferences
- These servers run locally (stdio) with a user-held token; they are not remote OAuth connectors, so they fit Claude Desktop/Code but not ChatGPT or Claude mobile. Penn blocks student token creation (per Smooth's CLAUDE.md), so this route fails for Penn students.

### Gaps
- Instructure's own MCP/developer announcements not read; whether any server supports submitting assignments (most appear read-only) was not verified.

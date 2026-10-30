# Delegated web sessions for agents (Smooth / Canvas), as of 2026-10-30

Scope note: ~20 tool calls, mostly web-search summaries (the search tool returns model-written summaries, not raw pages). Primary pages fetched in full: MCP authorization spec (draft), Browserbase Contexts. OpenAI help page returned 403. Items marked "unfetched" rest on search summaries only. Several questions had no sources found; see each Gaps list.

## 1. Architectures for delegating an authenticated web session to an agent

### Takeaway
Every vendor that offers "persistent login" for agents does it by (a) a one-time human login in a browser that the vendor controls or syncs from, then (b) storing the resulting cookie/profile state and replaying it, and all say sites can still expire it and force re-login. None documents importing arbitrary external cookies except Browser Use (syncs from a local Chrome). The phone-as-proxy and Mac-companion options had no direct precedent found.

### Cited Findings
- (c, cloud browser) Browserbase Contexts: a Context is created via API, its ID passed to new sessions, and writes require `persist: true`. Vendor says: "Contexts live indefinitely" on its infra, are "uniquely encrypted at rest", but sites may expire auth cookies (e.g. 30 days) or invalidate on password change/server-side logout; avoid concurrent sessions on one Context since sites may force logout. The page documents no cookie-import method. Recommended flow: log in once manually via Session Live View. — [Browserbase Contexts](https://docs.browserbase.com/platform/browser/core-features/contexts) (fetched); [Browserbase auth guide](https://docs.browserbase.com/platform/identity/authentication)
- Steel: three mechanisms. Auth "context" = snapshot of cookies+localStorage captured from a live Steel session via `sessions.context()` and passed into a new session (keyed by origin; treat as sensitive, contains session tokens). Profiles = User Data Directory snapshot, off unless `persistProfile: true`. Credentials vault fills login forms per origin; docs suggest auth-context for SSO/MFA/magic-link flows the vault cannot handle. No dedicated external-cookie import endpoint found. — [Steel reusing auth context](https://docs.steel.dev/overview/sessions-api/reusing-auth-context); [Steel profiles](https://docs.steel.dev/overview/profiles-api/overview); [Steel credentials](https://docs.steel.dev/cookbook/credentials) (search summaries)
- Hyperbrowser: profiles store cookies, localStorage, sessionStorage, cache; `persistChanges` must be enabled on first use; profiles reusable until deleted; blog says treat profiles like credentials. — [Hyperbrowser profiles](https://hyperbrowser.ai/docs/sessions/profiles); [Hyperbrowser blog](https://www.hyperbrowser.ai/blog/never-log-in-again-reusing-user-profiles) (summary)
- Browser Use Cloud: a script run with an API key opens a local browser to choose accounts and uploads local login state, returning a `profile_id`; profile holds cookies/localStorage/saved passwords; docs recommend refreshing profiles older than 7 days because cookies expire. This is the only vendor found that imports state from outside its cloud. — [Browser Use profile sync](https://docs.browser-use.com/cloud/guides/profile-sync.md); [Browser Use auth](https://docs.cloud.browser-use.com/guides/authentication) (summary)
- Anchor Browser: Profiles save login state; user handles MFA during the one-time login and must log in again manually on expiry. "Managed authentication" stores credentials on an identity and runs login before each session (email OTP, TOTP, 1Password, custom MFA); manual secure-browser fallback for unsupported logins. — [Anchor managed authentication](https://docs.anchorbrowser.io/essentials/managed-authentication); [Anchor cookie blog](https://anchorbrowser.io/blog/cookie-management-in-browser-automation-persistence-and-security) (summary)
- (d, agent in user's own browser) OpenAI: Atlas agent mode has a "logged-in" mode that uses sites the user is signed into and a "logged-out" mode that does not use existing cookies; cookies persist across sessions like a normal browser; the separate cloud browser does not inherit the laptop's sessions and prompts the user to "take over" for logins. Safeguards named: confirmations for high-impact actions, prompt-injection monitoring, "watch mode". — [OpenAI Atlas agent mode](https://help.openai.com/en/articles/12628199-chatgpt-atlas-agent-mode); [OpenAI cloud browser](https://help.openai.com/articles/11752874) (search summaries only; fetch returned 403)
- Anthropic's Claude for Chrome runs in the user's own Chrome (pilot announced Aug 2025). Anthropic reported prompt-injection success 23.6% without mitigations and 11.2% with them (123 cases/29 scenarios; Computer Use baseline 19.4%). — [Anthropic: Claude for Chrome](https://www.anthropic.com/news/claude-for-chrome) (summary). A figure of 0-0.3% in later evals appears only in a secondary source I could not verify.
- (a) WKHTTPCookieStore exposes `getAllCookies` and `setCookie(_:completionHandler:)`, iOS 11+/macOS 10.13+, obtained from a WKWebsiteDataStore, so cookies can be read from and injected into a web view programmatically. — [Apple WKHTTPCookieStore](https://developer.apple.com/documentation/webkit/wkhttpcookiestore)
- 1Password Agentic Autofill (with Browserbase Director, announced 2025-10-08): the agent requests a credential, the human approves in 1Password, 1Password fills password or one-time code, the agent never receives the value, and it is removed after login. Vault/login allowlisting by admins and audit logs. Rollout stage reported inconsistently (early access vs open beta). — [1Password blog](https://1password.com/blog/closing-the-credential-risk-gap-for-browser-use-ai-agents); [Browserbase blog](https://browserbase.com/blog/browserbase-is-partnering-with-1password-for-agents/); [SiliconANGLE](https://siliconangle.com/2025/10/08/1password-tackles-ai-credential-risks-new-agentic-autofill-integration-browserbase/)

### Inferences
- Pattern across vendors: cookie replay works until the site's idle/absolute timeout or a server-side invalidation; none claim to beat it. For SAML+Duo Canvas, a cloud-browser copy of the session is a second client on the same Canvas session, subject to the same timeouts (we infer; Canvas-specific behavior not researched).
- Cookie export (a) is mechanically feasible via WKHTTPCookieStore, but a copy handed to a cloud browser is a bearer credential at rest in a third party; Browser Use's "refresh after 7 days" suggests the phone would need to re-push cookies on every renewal.
- Phone-as-proxy (b) and Mac companion (e) are not described by any vendor found; they are Smooth-specific designs, not established patterns.

### Gaps
- Not found: any vendor doc on IP/User-Agent binding or cookie rotation breaking replayed sessions; Instructure/Canvas docs on session binding and timeouts.
- Not found: Tailscale/relay/WebSocket-to-phone precedents, Lightpanda/Kernel/Steel import of external cookies (Steel and Browserbase docs show none).
- Not researched: Perplexity Comet, Claude for Chrome persistence specifics beyond "uses your Chrome profile", Mac MCP-server precedents (stdio/localhost MCP is permitted by the spec; see section 5).

## 2. iOS platform constraints

### Takeaway
Keychain sharing is team-scoped, silent push is best-effort and cannot be relied on to wake the app, and WKWebView runs out of process with a non-adjustable memory limit. I found no Apple-sanctioned way for a phone's web session to be used by another device, but I did not search specifically for one.

### Cited Findings
- Keychain items can be shared only among apps from the same developer team via `keychain-access-groups`; an app from a different team cannot access them. Xcode prefixes groups with the team ID. — [Apple: sharing keychain items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps); [Apple forum 723715](https://developer.apple.com/forums/thread/723715)
- Silent (`content-available`) pushes are throttled when the app is backgrounded; delivery not guaranteed; not delivered to force-quit apps; forum guidance points to a Notification Service Extension for visible pushes (which does not run for silent ones). Sources are mostly Apple Developer Forum posts of iOS 13-15 era. — [Apple forum 756001](https://developer.apple.com/forums/thread/756001); [forum 126540](https://developer.apple.com/forums/thread/126540); [forum 835645 (pushDisallowed on TestFlight)](https://developer.apple.com/forums/thread/835645)
- WKWebView does its work out of process; the WebContent process is terminated past an internal memory limit that cannot be raised and varies with device RAM. — [Apple forum 771787](https://developer.apple.com/forums/thread/771787); [forum 21956](https://developer.apple.com/forums/thread/21956)
- Project's own CLAUDE.md records that background refresh crashes on every wake in 3.0.0 and that no background renewal has ever run (project doc, not external).

### Inferences
- A phone-resident proxy would in practice require the app foregrounded or a visible push the user taps; an unattended agent cannot depend on waking it.
- A different-team agent app cannot read Smooth's Keychain items; only same-team apps could.

### Gaps
- Not found: App Intents / Shortcuts running WKWebView in the background (search returned only generic WKWebView memory threads); Safari Web Extension cookie access; BGTaskScheduler limits (not searched); Live Activities; Network Extension/Tailscale-style tunnels; Apple-sanctioned cross-device session sharing; App Store Review Guidelines 5.1.1/2.5/4.x on credential sharing or remote control (not searched; do not assume).

## 3. Standards and guidance

### Takeaway
MCP's authorization spec (HTTP transports) makes the MCP server an OAuth 2.1 resource server with a separate authorization server; stdio servers should not use it. Delegation drafts exist but are individual or preview-stage.

### Cited Findings
- MCP draft authorization spec: authorization is OPTIONAL; HTTP transports SHOULD conform; STDIO "SHOULD NOT follow this specification, and instead retrieve credentials from the environment". MCP server = OAuth 2.1 resource server; MUST implement RFC 9728 Protected Resource Metadata; clients MUST use RFC 8707 `resource` parameter and PKCE; servers MUST validate token audience and "MUST NOT accept or transit any other tokens"; scope step-up via 403 `insufficient_scope`; Client ID Metadata Documents preferred, Dynamic Client Registration deprecated; the AS may be hosted with the resource server. — [MCP authorization (draft)](https://modelcontextprotocol.io/specification/draft/basic/authorization) (fetched in full)
- IETF individual draft "OAuth 2.0 Extension: On-Behalf-Of User Authorization for AI Agents" (WSO2 authors) adds `requested_agent` and a new grant type; revision -02 Aug 2025; reported as not adopted by the OAuth WG (check datatracker). — [draft -02](https://datatracker.ietf.org/doc/html/draft-oauth-ai-agents-on-behalf-of-user-02); [WorkOS commentary](https://workos.com/blog/oauth-on-behalf-of-ai-agents)
- Microsoft Entra Agent ID: agent blueprints with child agent identities, OAuth OBO flow for acting for a signed-in user; public preview since May 2025. — [Microsoft Learn: agent OBO flow](https://learn.microsoft.com/en-us/entra/agent-id/agent-on-behalf-of-oauth-flow)
- Tool-auth brokers: Composio (central encrypted credential vault, policy checks in request path, per claims in a Composio-authored comparison) and Arcade (just-in-time authorization URL, agent never sees raw token). Vendor-biased sources. — [Composio vs Arcade](https://composio.dev/blog/composio-vs-arcade); [Firecrawl roundup](https://www.firecrawl.dev/blog/best-ai-agent-authentication-platforms)
- OWASP Top 10 for Agentic Applications (Dec 2025): ASI03 "identity and privilege abuse"; recommended mitigations in secondary write-ups include ephemeral credentials, per-action authorization via a policy engine, least privilege, logging. Primary OWASP doc not fetched. — [Descope summary](https://www.descope.com/blog/post/owasp-agentic-top-10-identity); [Tenable](https://it.tenable.com/blog/cybersecurity-snapshot-owasp-agentic-ai-top-10-mitre-dangerous-software-weaknesses-12-12-2025)

### Inferences
- If Smooth (Mac or a relay) exposed an MCP server, remote agents would reach it over HTTP with OAuth where Smooth/its backend is the authorization server and resource server; a local desktop agent could use stdio with credentials from the environment. Neither precedent for a Canvas-session-backed server was found.
- Canvas itself would not see an OAuth token from this chain; the OAuth layer would only authorize the agent to Smooth, while Smooth still acts on Canvas with the student's cookie.

### Gaps
- RFC 8693 token exchange, Auth0 for AI Agents, Google agent identity work, Anthropic/OpenAI credential-handoff guidance: not retrieved. Primary OWASP and arXiv prompt-injection papers not retrieved.

## 4. Threat model

### Takeaway
Sources agree an agent holding a live logged-in session can act as the user, and prompt injection is the main way that goes wrong; the common mitigations are keeping credentials from the model, human approval, and short-lived or per-action authorization.

### Cited Findings
- OpenAI says a signed-in agent can reach sensitive emails, files and settings, and offers logged-out mode, takeover for credentials and confirmations for high-impact actions. — [OpenAI Atlas agent mode](https://help.openai.com/en/articles/12628199-chatgpt-atlas-agent-mode) (summary)
- Anthropic measured residual prompt-injection success of 11.2% even with mitigations (Aug 2025 pilot); Simon Willison called this still unacceptable. — [Anthropic](https://www.anthropic.com/news/claude-for-chrome); [Willison](https://simonwillison.net/2025/Aug/26/piloting-claude-for-chrome/)
- Vendors say saved profiles/contexts are credentials: Steel ("contains session tokens"), Hyperbrowser, Anchor. See section 1 links.
- 1Password's design keeps the secret out of the agent's context and requires human approval per request by default. — [1Password blog](https://1password.com/blog/closing-the-credential-risk-gap-for-browser-use-ai-agents)
- MCP spec requires audience-bound tokens and forbids token passthrough; security-considerations page covers confused deputy and token theft. — [MCP authorization](https://modelcontextprotocol.io/specification/draft/basic/authorization)

### Inferences
- A minimal-capability design would expose a few allowlisted verbs (for example "submit file X to assignment Y"), execute them inside Smooth (phone or Mac) with the cookie never leaving it, require on-device confirmation before submit, and issue short-lived audience-bound tokens to the agent. This follows the 1Password/Arcade pattern of keeping the credential out of the agent; no source describes it for Canvas.
- Duo trust cookies (30-day `browsertrust`, per project CLAUDE.md) are as sensitive as the session cookie and should never be exported (we infer).

### Gaps
- No source found on a relay-server compromise model, Duo trust cookie theft specifics, or academic-integrity/Instructure policy on third-party submission by agents (not searched; likely material for the report writer).

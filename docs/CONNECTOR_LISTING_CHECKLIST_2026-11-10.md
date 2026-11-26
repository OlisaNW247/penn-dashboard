# Connector listing checklist: ChatGPT and Claude's directory, 2026-11-10

What OpenAI (ChatGPT apps / custom MCP servers) and Anthropic (the Claude
connector directory) ask of a remote MCP server today, what Smooth's agent
connection already does, and what a submission needs from Marco. Read from the
platforms' live docs on 2026-11-10 (URLs per section). These pages change;
re-read them before submitting. OpenAI's help-center pages answered 403 to the
reader, so the ChatGPT plan matrix below is the least certain line here.

Smooth's side, for reference: the MCP server is
`https://smooth-agent.vercel.app/functions/v1/mcp`, its authorization server
`.../functions/v1/agent-auth` (our own, `backend/PROTOCOL.md` → "The agent
connection"), the front `backend/connector-front/` answers the root discovery
paths.

## Both platforms: OAuth and discovery

| Requirement | Claude | ChatGPT | Smooth | Where |
|---|---|---|---|---|
| 401 with `WWW-Authenticate` naming `resource_metadata` | required | accepted (or the root PRM) | yes, plus `scope="read draft"` | `_shared/agentMetadata.ts` `bearerChallenge` |
| Protected Resource Metadata, `resource` equal to the MCP URL, first `authorization_servers` entry is ours | required | required (`issuer` must equal the entry) | yes | `agentMetadata.ts` `protectedResourceMetadata`; root path via `connector-front/main.ts:66` |
| AS metadata at `/.well-known/oauth-authorization-server` (or `openid-configuration`) | required | required | yes, both names, root and path forms | `connector-front/main.ts:69`, `agentMetadata.ts` `authorizationServerMetadata` |
| PKCE S256, advertised in `code_challenge_methods_supported` | required | required ("servers that omit it are unsupported") | yes | `agentMetadata.ts`, `agentAuth.ts` `verifyPKCE` |
| `resource` (RFC 8707) on authorize and token | sent | sent, and expected in the token's audience | yes: must equal the MCP URL, `invalid_target` otherwise; the token is bound to the connection | `agentAuth.ts` `validateAuthorizeRequest` |
| RFC 9207 `iss` on every authorization response, success and error, plus `authorization_response_iss_parameter_supported: true` | not stated | **required**, exact string match | yes, every redirect carries `iss` | `agent-auth/index.ts` `redirectWith` (`iss` always set), `agentMetadata.ts` |
| CIMD (client id is an https URL) | preferred when the AS lists `client_id_metadata_document_supported: true` and `none` | preferred; ChatGPT's id is `https://chatgpt.com/oauth/client.json` or `.../oauth/{callback_id}/client.json` | yes, both flags; any https client id on a public name is fetched and must vouch for the redirect URI | `agentAuth.ts:47` `isCIMDClientId`, `validateClientMetadata` |
| DCR (RFC 7591) | fallback | accepted; registers once per connection | yes, public clients only (`none`) | `agentAuth.ts` `validateRegistrationRequest`; root `/register` via the front |
| Redirect URIs | `https://claude.ai/api/mcp/auth_callback`; Claude Code: loopback on any port | `https://chatgpt.com/connector_platform_oauth_redirect`, or `https://chatgpt.com/connector/oauth/{callback_id}` | any https URI the client registers or its CIMD vouches for; loopback http with the port ignored | `agentAuth.ts` `isAcceptableRegisteredRedirect`, `redirectURIMatches` |
| Scopes in `scopes_supported`; `offline_access` | Claude appends `offline_access` when listed | not stated | `read draft offline_access` | `agentMetadata.ts` `AGENT_SCOPES` |
| Refresh rotation; dead refresh is `invalid_grant`; form-urlencoded `/token` | required | "tokens can expire or rotate normally" | yes, with reuse detection revoking the connection | `agent-auth/index.ts` token handler; proven live by `backend/scripts/agent-e2e.mjs` |
| Endpoint latency: 10 s for discovery, registration and token, 30 s for refresh; reachable from `160.79.104.0/21` | stated | not stated | the live token call took 2.75 s (function log, 2026-11-10 05:55 UTC); no IP filter anywhere | |
| `403 insufficient_scope` for step-up | stated | via `_meta["mcp/www_authenticate"]` on a tool error | a `read`-only token calling `propose_submission` gets a tool error ("this connection cannot propose drafts"), not a 403 or the `_meta` challenge | `_shared/agentTools.ts` `propose_submission` (gap, below) |

## Both platforms: tools

| Requirement | Smooth | Where |
|---|---|---|
| Every tool has a `title` (Claude) | yes, pinned by a test | `agentTools.ts` `registerTools`; `test/mcpHandler.test.ts` "titles and annotations" |
| Claude: `readOnlyHint: true` on reads, `destructiveHint: true` on anything that modifies or deletes; read-only tools skip the per-call prompt | reads yes. `propose_submission` is `readOnlyHint: false` with `destructiveHint: false` by default (it writes a draft the student must approve, nothing leaves Smooth). Whether Claude's reviewers accept `false` here is the open question; `LHF_MCP_PROPOSE_HINT=true` flips it without a deploy of code | `agentTools.ts` `readOnly`, `propose_submission` annotations |
| ChatGPT: `readOnlyHint`, `destructiveHint`, `openWorldHint` as explicit booleans on **every** tool | **yes since this commit**: the read tools used to carry only `readOnlyHint`; they now state all three (`destructiveHint: false`, `openWorldHint: false`). `propose_submission` states all three unless `LHF_MCP_PROPOSE_HINT=none`, which must stay unset for ChatGPT | `agentTools.ts` `readOnly`; `test/mcpHandler.test.ts` |
| Read and write split into separate tools; no tool mixing safe and unsafe actions | yes: one write (`propose_submission`), everything else reads | `agentTools.ts` |
| Tool names at most 64 characters; descriptions accurate and free of instructions to the model | yes (longest is `search_course_material`); descriptions describe, they do not instruct | `agentTools.ts` |
| Errors actionable, not generic | yes: "no such assignment", "too many open drafts; the student must review them in Smooth first", size limits named | `agentTools.ts` |
| No money movement, no AI media generation, no reading the client's memory or chat history | none of these exist | |
| Human confirmation for irreversible actions (ChatGPT) | nothing irreversible exists: a draft is reviewed and submitted by the student in Smooth; the agent has no submit tool (a standing rule) | `docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md` Decisions |

## Gaps in code (not done here, each small)

1. **Step-up challenge for a `read`-only token.** Claude wants `403` with
   `insufficient_scope` and ChatGPT wants `_meta["mcp/www_authenticate"]` on
   the tool error, so a client can ask for `draft`. Today the student sees a
   plain tool error. Matters only for a connection approved without `draft`,
   which our sign-in never offers (the page asks for what the client asked
   for, and both clients ask for everything in `scopes_supported`). Low.
2. **Per-tool `securitySchemes`** (ChatGPT): optional metadata declaring
   `oauth2` with the scopes each tool needs. Not needed for a server whose
   every tool needs sign-in.
3. **Server icon and title in `initialize`.** `McpServer` is created as
   `{ name: "smooth", version: "0.1.0" }` (`mcp/index.ts:56`). The directory
   forms take the icon themselves, so this is cosmetic, but it needs a hosted
   square PNG first (item 3 under "From Marco").

## ChatGPT specifics

Sources: https://developers.openai.com/apps-sdk/build/auth,
https://developers.openai.com/apps-sdk/deploy/connect-chatgpt,
https://developers.openai.com/apps-sdk/deploy/submission,
https://developers.openai.com/apps-sdk/app-submission-guidelines.

- **Trying it (no review):** chatgpt.com → plugins (formerly connectors,
  "developer mode") → "Add custom MCP server" → the MCP URL above. Needs a
  public https Streamable HTTP endpoint, which we have. **Which plans may add
  one is unconfirmed:** a search summary of OpenAI's help center says write
  actions are Business, Enterprise and Edu (admins enable it), and third
  parties disagree about Plus and Pro. Marco should check
  https://help.openai.com/en/articles/12584461 signed in, then try it.
- **Submitting an app:** by an organisation owner (or "Apps Management
  Write"); individual or business identity verification for the publisher's
  name to show; `privacyPolicyURL`, `termsOfServiceURL`, `supportURL` (all
  https); a square logo, at least 48 x 48, PNG/JPEG/WebP/SVG, at most 5 MiB;
  exactly five positive and three negative test prompts; a demo recording
  URL; and, because sign-in is needed, a test account that works without MFA
  or SMS codes. Auth in the portal: OAuth with registration `dcr` or `cimd`.
- **The privacy policy must state** data categories, purposes, recipients,
  retention and user controls. `docs/PRIVACY.md` → "Connecting an AI
  assistant" covers the first four for the agent connection; retention of
  the snapshot ("replaced on every upload, deleted on opt-out") and of
  drafts should be said in one sentence each before submitting.

## Claude directory specifics

Sources: https://claude.com/docs/connectors/building/submission,
https://claude.com/docs/connectors/building/review-criteria,
https://claude.com/docs/connectors/building/authentication; the Software
Directory Terms and Policy (support.claude.com articles 13145338 and
13145358, not read here).

- **Where:** claude.ai/directory/manage → Submit new → MCP connector. Any
  paid Claude plan. Steps: connection, tools, listing, use cases, company,
  authentication, data handling, test and launch, compliance, review.
- **Listing:** name (≤ 100 characters), one-liner (≤ 200), description
  (≤ 2,000), 1 to 5 categories, documentation URL, privacy policy URL,
  support contact, icon (no size stated on the pages read), a permanent URL
  slug.
- **Test account:** required, fully populated, with access instructions;
  and a confirmation that every tool was run through MCP Inspector or as a
  custom connector (done for the read tools on 2026-11-09 on Marco's
  claude.ai; `propose_submission` has only been run by `agent-e2e.mjs`).
- **Seven compliance acknowledgements** (guidelines, first-party API,
  financial transactions, AI media, prompt injection, conversation data,
  public docs). **Public documentation** must exist by the publish date; a
  help article or blog post is enough.
- **Outcome:** an automated scan, listed as "Community" by default; human
  review and "Verified" are slower. Escalations: `mcp-review@anthropic.com`.
- **DCR at volume:** Anthropic recommends CIMD (which we support) over DCR
  for directory servers, since DCR registers a client per fresh connection.
  Claude picks CIMD by itself when our metadata lists both flags, which it
  does.

## The test account problem, for both

Both reviews need a test account that signs in without MFA. Our sign-in is
pairing with a phone that has a Penn Canvas session: a reviewer has neither.
Options, for Marco to choose:

1. A **reviewer path in `agent-auth`**: a fixed, revocable reviewer code
   that approves itself against a demo snapshot (the app's own "Preview with
   sample data" posture, which App Review already accepts for the app). The
   honest version of a test account; a contained piece of work; needs a
   decision because it is a second way in.
2. Marco pairs a reviewer by hand during a scheduled review window. Fragile.

## What a submission needs from Marco

1. **Accounts:** an OpenAI organisation with identity verification (and the
   plan that allows custom MCP servers, item above); a paid Claude account
   for the directory portal (his claude.ai is one). Whether the publisher is
   Stem Forward Co. (the App Store team) or Marco is his and Olisa's call.
2. **A privacy policy URL.** `docs/site/privacy.html` still says "Low Hanging
   Fruit" and nothing about agents, and is not served at
   `olisanw247.github.io/penn-dashboard/` (404 on 2026-11-10). The metadata
   points at the GitHub view of `docs/PRIVACY.md` on `v10`
   (`agentMetadata.ts` `service_documentation`), which is current but is a
   repository page. The App Store listing's privacy URL is whatever App
   Store Connect holds; use the same page, updated with the agent section.
3. **A logo:** a square PNG of the S mark, at least 512 x 512 to be safe
   for both, hosted at a stable https URL (the front could serve it at
   `https://smooth-agent.vercel.app/icon.png`).
4. **Terms of service URL** (ChatGPT requires one; there is none today).
5. **A support URL:** `docs/site/support.html` (mailto
   `lowhangingfruit.help@gmail.com`, old branding) hosted somewhere, or any
   page with a contact.
6. **Public documentation** of the connector (a help page: what it reads,
   that it never submits, how to disconnect).
7. **The test-account decision** above.
8. **Five positive and three negative test prompts** and a short screen
   recording (ChatGPT).

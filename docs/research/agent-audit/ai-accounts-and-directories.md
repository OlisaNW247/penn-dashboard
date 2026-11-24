# Can a student use their own Claude or ChatGPT account through Smooth?

Researched 2026-11-23 from official pages. Many pages show only "Updated N days ago"; dates are noted where shown. Search results were secondary for a few points, flagged "(secondary)". Not blocked: every host I tried loaded. Not read: OpenAI's partner directory and plan-usage developer docs (I read OpenAI's help page and a WorkOS write-up instead); Anthropic's Consumer Terms full text (search snippets only); OpenAI's Apps SDK submission page (I read the developer guidelines and app-review page).

## (a) Smooth uses the student's consumer subscription inside Smooth

### Anthropic: not allowed
- Claude Code legal page (no date shown): "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users." Also: developers "may not collect, store, or intermediate Claude.ai credentials or session tokens". Developers, "including those using the Agent SDK", should use API-key auth. https://code.claude.com/docs/en/legal-and-compliance
- The same page says OAuth "is intended exclusively for purchasers" of the plans and for native Anthropic apps, and that Anthropic "may do so without prior notice" when enforcing.
- Narrow carve-out: an end user may sign in to the unmodified Claude Code binary with their own plan, including where a platform hosts it. That is Claude Code itself, not a custom app like Smooth.
- Timeline (secondary): Feb 19, 2026 docs update banned subscription OAuth in third-party tools (https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/). Per VentureBeat, a 4 April 2026 restriction was reversed on 13 May 2026 and replaced with a separate monthly "Agent SDK" credit for programmatic use (Pro $20, Max 5x $100, Max 20x $200), billed at API rates, expiring monthly, metered from June 15: https://venturebeat.com/ai/anthropic-reinstates-openclaw-and-third-party-agent-usage-on-claude-subscriptions-with-a-catch/ . I could not reconcile this credit model with the legal page's still-standing prohibition; the legal page is the authoritative text and I would treat the credit as applying to existing third-party tools that Anthropic tolerates, not as permission for a new commercial app to broker logins. A GitHub bug report (secondary) shows plan credentials in third-party apps returning "Third-party apps now draw from extra usage, not plan limits": https://github.com/NousResearch/hermes-agent/issues/48176
- Consumer Terms (search snippets, versions vary): bars sharing login info/credentials and automated access "except when you are accessing our Services via an Anthropic API Key or where we otherwise explicitly permit it". https://www.anthropic.com/legal/consumer-terms

### OpenAI: now possible, but only for approved partners
- "Sign in with ChatGPT" plan usage launched at DevDay 2026-09-29 with ~16 partners (secondary: https://workos.com/blog/sign-in-with-chatgpt-plan-usage-scope , https://thenewstack.io/sign-in-with-chatgpt/).
- OpenAI help article (shows "Updated: 11 days ago"): using your plan in commercial apps needs Go, Plus, Pro or Business; "We've launched with a limited set of partners"; commercial partners "must submit an interest form"; open-source developers use the developer docs. Sign-in shares name, email, picture; plan use does not by itself give access to conversations or memories. Users can cap each app's weekly share. https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites
- WorkOS (secondary): the developer docs are "written for open-source and locally hosted apps"; paid or hosted products are pointed to the interest form. Mobile apps are not addressed anywhere I read.
- OpenAI Terms of Use not separately read; the sanctioned route is this program, not scraping tokens.

### Per-criteria
| | Anthropic | OpenAI |
|---|---|---|
| Allowed? | No (quote above) | Only via the partner programme (interest form); not self-serve |
| Student gets | n/a | Smooth answers draw on their ChatGPT plan allowance, no key |
| Cost to Smooth | n/a, and risk of enforcement without notice | No inference cost; still need a server path or on-device client for tokens; unknown whether a mobile app qualifies |
| Privacy | Would require handling session credentials, which is itself prohibited | Smooth's questions plus context go to OpenAI under the student's account; Smooth gets name/email/picture on sign-in |
| Effort | Do not build | Apply to the interest form; then OAuth integration; uncertain |
| Verdict | Forbidden | Worth one email to OpenAI; do not plan around it. Only helps ChatGPT users |

## (b) Student's own Claude or ChatGPT uses Smooth as a remote MCP connector

### Claude: the sanctioned pattern, available now
- Anyone can add an unlisted remote MCP server by URL: custom connectors work on "Free, Pro, Max, Ultra, Team, and Enterprise plans"; "On the Free plan, you can add one custom connector." Connectors added to the account work on web, desktop and mobile ("Claude mobile app: remote connectors"). Adding via the Connectors page is documented for claude.ai and desktop; the mobile docs say connected connectors are usable there. https://claude.com/docs/connectors/custom/add-unlisted.md and https://claude.com/docs/connectors/overview
- Directory listing: submit at claude.ai/directory/manage by anyone on a paid Claude plan. Requirements: HTTPS remote server; OAuth 2.0 for authenticated services; every tool has a `title` and `readOnlyHint` or `destructiveHint`; documentation URL, privacy policy URL, support contact, icon; seven compliance acknowledgments (including conversation data collection, prompt injection, financial transactions). Default outcome: automatic scan, then listed as "Community"; some get human "Verified" review. https://claude.com/docs/connectors/building/submission.md
- Review criteria (quote): a tool mixing safe and unsafe methods "is rejected"; must split read and write tools. Not accepted: connectors that "Transfer money, cryptocurrency" or "Generate images, video, or audio". https://claude.com/docs/connectors/building/review-criteria.md
- Directory Policy (undated, "Updated over a month ago"): no ads/sponsored content; "Software must only collect data from the user's context that is necessary"; remote servers needing auth "must use secure OAuth 2.0". The policy page did not address academic dishonesty. https://support.claude.com/en/articles/13145358-anthropic-software-directory-policy

### ChatGPT: narrower
- Help article (shows "Updated: 27 days ago"): custom MCP is for Business/Enterprise/Edu; Pro "can build apps with the Apps SDK and connect custom MCP servers with read/fetch permissions"; "Full MCP is not available"; connecting custom MCP servers is "web only" (not mobile). Plus and Free are not addressed by that page; older coverage (secondary) says Free has no connectors, Plus/Pro got developer mode. Treat Plus/Free as unconfirmed. https://help.openai.com/en/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt
- Directory submission is now via the "plugins" flow (OpenAI Platform dashboard). App review page: publisher must be identity-verified or "will result in rejection"; public HTTPS server; demo account with no MFA; annotations must match behavior; EU-data-residency projects cannot submit. https://developers.openai.com/plugins/deploy/app-review.md
- Developer guidelines: clear privacy policy (4.1); data minimization (4.2a); never collect "access credentials or authentication secrets such as API keys, MFA/OTP codes, and passwords" (4.2b); general audience including ages 13-17, mature experiences unsupported (3.2); `readOnlyHint`, `destructiveHint`, `openWorldHint` explicit on every tool (6.3); no ads; no executing money or crypto transactions; "Plugins must not seek secrets or protected context". Plugins may not facilitate activities prohibited by OpenAI's usage policies (3.1). https://developers.openai.com/apps-sdk/app-developer-guidelines
- Implication for Smooth: Canvas content and grades flow into ChatGPT or Claude under the student's chat, so the connector's privacy policy must say so. A connector that stores Canvas cookies or passwords for the student would collide with the credentials rule; it must pull from Smooth's own server using OAuth and data the phone chose to sync.

### Per-criteria
| | Claude | ChatGPT |
|---|---|---|
| Allowed? | Yes, explicitly | Yes, limited (Pro read-only, web only per help page) |
| Student gets | Their own Claude (Free: one connector) can read their Smooth work list and call tools, on web/desktop/mobile | Same, but desktop web; write actions need business plans |
| Cost to Smooth | Server-side MCP endpoint plus OAuth; inference paid by student | Same |
| Privacy | Data leaves Smooth's server into the student's own chat; must be disclosed; server must hold the student's data, which conflicts with the current "stays on device" posture unless the phone uploads a snapshot | Same |
| Effort | Moderate: OAuth + MCP server + annotations; directory submission optional | Moderate; submission needs verified publisher |
| Verdict | Do this first; works unlisted today | Do second; narrower plans and no mobile |

## (c) Bring-your-own API key

- Anthropic: the Claude Code legal page says developers building products "should use API key authentication through Claude Console"; and this "does not restrict how customers provision and manage their own API keys... provided the resulting usage is billed to the key owner... and is not resold or intermediated". So a user-supplied key used by the user's own app copy is consistent with that text. I did not read Anthropic's Commercial Terms line by line.
- OpenAI: key-safety help article advises against exposing keys in browsers or mobile apps and routing through your own backend (secondary summary): https://help.openai.com/en/articles/5112595-best-practices-for-api-key-safety . That is about the developer's key; a user's own key in their own app is not addressed. A community feature request notes OpenAI has no browser-safe key type: https://community.openai.com/t/feature-request-restricted-byok-api-keys-for-client-side-applications/1392506
- App Store: developer forum reports of Guideline 3.1.1 rejections where a user-entered key "unlocks or enables" functionality (threads: https://developer.apple.com/forums/thread/763884 , https://developer.apple.com/forums/thread/856121 ). These are individual accounts, not rulings; Apple's text is about unlocking features outside in-app purchase. Risk is real if the key gates paid features; lower if the key only powers an AI helper and Smooth is otherwise free.
- Uptake: no source gives numbers; my judgment is that very few undergraduates hold an API key and billing account. Treat as a power-user option.

| | |
|---|---|
| Allowed? | Yes by provider terms for the key owner; App Store 3.1.1 is an open risk |
| Student gets | Ask answered on their own key, no Smooth bill |
| Cost to Smooth | Near zero server cost; support burden |
| Privacy | Good if calls go phone-to-provider directly: Smooth never sees the key (Keychain) or the content. Key on phone is extractable only from that student's device |
| Effort | Small-moderate (settings screen, direct client, on-device context) |
| Verdict | Optional power-user fallback; low uptake; ask App Review before relying on it |

## (d) Platform routes with no student account

- Apple Foundation Models (on-device): free, offline, "no inference costs"; needs iPhone 15 Pro or newer with Apple Intelligence (secondary: https://www.digit.in/news/general/ios-27-release-when-will-iphone-17-iphone-16-and-older-iphones-get-the-latest-update-and-apple-intelligence-features.html ). iOS 27 shipped 2026-09-14 per https://9to5mac.com/2026/09/09/apple-confirms-ios-27-release-date-september-14/ . Smooth already uses it as ask's fallback.
- Apple Private Cloud Compute for third parties: yes as of WWDC 2026. Apple (June 2026): developers can access the next-generation Apple Foundation Models on PCC; developers in the Small Business Program with "fewer than 2 million total first-time App Store downloads" use them "at no cloud API cost". Pricing for others and device requirements not stated. Needs OS 27. https://www.apple.com/newsroom/2026/06/apple-aids-app-development-with-new-intelligence-frameworks-and-advanced-tools/ and https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/ . I could not confirm Smooth's eligibility (it is a Stem Forward Co. app; check the Small Business Program status).
- Anthropic App Attest for iOS: it exists. "Let genuine installations of your iOS or macOS app call the Claude API without shipping an API key or running a proxy." Usage "bills to your workspace" (the developer's), tokens last 1 hour, Messages API only, "no end-user identity". Delivered through the "Claude for Foundation Models" Swift package, which is beta and needs OS 27 and Xcode 27. So it removes key shipping but does not shift cost to the student. https://platform.claude.com/docs/en/manage-claude/app-attest.md and https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models (the package also supports a `.proxied` mode through your own backend, which is what Smooth does now).
- Apple's ChatGPT integration: not available to third-party apps. A forum answer (not official) says there is "currently no way for 3rd party apps" to use a linked ChatGPT account; Apple's privacy page describes it as a user-enabled system extension: https://developer.apple.com/forums/thread/770710 , https://www.apple.com/legal/privacy/data/en/third-party-ai/ . Reports of a Siri Extensions API are plans, not shipped.
- OpenAI client secrets: ephemeral tokens exist only for the Realtime API (short-lived, minted by your backend); no general equivalent for text requests. https://developers.openai.com/api/docs/guides/realtime-webrtc.md

| | |
|---|---|
| Allowed? | Yes |
| Student gets | No account needed; on-device model for simple questions; PCC or Claude via App Attest for harder ones |
| Cost to Smooth | On-device: zero. PCC: zero if eligible. App Attest: Smooth pays API rates, same as now but no proxy |
| Privacy | On-device best. PCC claims strong privacy. App Attest sends content to Anthropic directly under Smooth's account |
| Effort | On-device done; PCC small once on OS 27; App Attest small but beta and OS 27 only |
| Verdict | Best default for the free tier; App Attest does not solve cost, only key hygiene |

## Academic dishonesty and the agent feature

- OpenAI Usage Policies (effective 2026-11-20 per the page; changelog 2026-10-21): under "Empower people", prohibited uses include "academic dishonesty", also "deceit, fraud, scams, spam, or impersonation". https://openai.com/policies/usage-policies/
- Anthropic Usage Policy (effective Nov 12, 2026 per the page): no explicit "academic dishonesty" term; under fraudulent practices it prohibits "Plagiarize or submit AI-assisted work without proper permission or attribution". https://www.anthropic.com/legal/aup
- Directories: Anthropic's directory policy and review criteria say nothing on academic dishonesty, but listings must comply with the Usage Policy; OpenAI's guidelines require plugins not facilitate activities prohibited by its usage policies (3.1). Neither page says anything about submitting work on a user's behalf, but both reject deceptive behavior and require that annotations match behavior; a tool that submits assignments would be `destructiveHint: true` with irreversible-send language. Reading and planning tools carry no such risk. Keep the connector read-only (work list, due dates, syllabus facts) and do not offer a "submit" tool.

## Overall recommendation

Do not try to use students' Claude or ChatGPT subscriptions inside Smooth: Anthropic forbids it in plain words, and OpenAI allows it only for approved partners through an interest form that does not clearly cover a hosted mobile app. The sanctioned way to let a student spend their own plan is the connector route: a read-only remote MCP server with OAuth that a student adds by URL (works today on Claude Free, Pro and Max including mobile, one connector on Free; ChatGPT is narrower and web-only), with directory listing as an optional later step. Keep Smooth's own ask on the platform routes: the on-device model for free and offline, Apple's Private Cloud Compute if Smooth qualifies for the free tier, and the current server key (or App Attest) for the hardest questions. Offer bring-your-own key only as a power-user toggle after checking with App Review. Keep any agent tools read-only; that avoids both policy files' academic-dishonesty language and the directories' write-tool rules.

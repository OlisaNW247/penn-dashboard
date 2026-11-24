# Personal AI accounts via Apple's platform: routes for Smooth (researched 2026-11-24)

Blocked: theverge.com (search tool refused it). thenextweb.com fetch reset. Not read: WWDC session 240/345 transcripts, Apple's Extensions docs (none found), Claude mobile deep-link article.

## 1. iOS 27 "Extensions" (third-party AI provider choice)
Status: NOT confirmed shipped. Bloomberg/MacRumors reported it (2026-03/05); Apple did not announce it.
- MacRumors, 2026-06-09 (reporting Bloomberg, 2026-05-05): "Extensions allow you to access generative AI capabilities from installed apps on demand". Named Siri, Writing Tools, Image Playground. https://www.macrumors.com/2026/06/09/ios-27-third-party-chatbots-apple-intelligence/
- Apple's WWDC (2026-06-08) and ship (2026-09-14) newsroom posts do not mention Extensions, ChatGPT or third-party models in the pages read. https://www.apple.com/newsroom/2026/06/apple-unveils-next-generation-of-apple-intelligence-siri-ai-and-more/ , https://www.apple.com/newsroom/2026/09/major-updates-for-apples-software-platforms-are-now-available/
- Low-credibility blog (assindo.com, undated): "no Claude, Gemini or Grok extension registers with Siri on shipping devices"; framework present but not switched on. https://assindo.com/news/ios-27-siri-extensions-best-ai-assistant-iphone . Other search hits disagree; verify on a device.
- Whether a third-party app's Writing Tools / Foundation Models call would route to the user's chosen provider: no source says so. Reports describe extensions serving Apple surfaces (Siri, Writing Tools, Image Playground). Unproven for third-party apps.

## 2. Foundation Models framework, provider packages
- Apple WWDC26 session 339 (https://developer.apple.com/videos/play/wwdc2026/339/): "Anthropic and Google will soon extend the Foundation Models framework with Swift packages of their own"; also "help developers do the right thing by offering a token provider or sign in flow." Context is developers not hardcoding API keys. The transcript does not discuss end users linking their own account. PrivateCloudComputeLanguageModel: "now with reasoning, a 32K token context window"; apps call it with `LanguageModelSession(model:)`.
- Anthropic package docs (beta, OS 27 betas): https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models
  - "Usage is billed to your Anthropic account at standard API pricing" (the developer's).
  - Auth modes: `.appAttest`, `.proxied`, `.apiKey` only. No end-user sign-in mode.
  - App Attest: "bills usage to your workspace"; tokens "carry no end-user identity: App Attest identifies your app, not the person using it."
  - App Attest page: https://platform.claude.com/docs/en/manage-claude/app-attest
- Google package: not found/read. Apple forum thread (no provider billing info): https://developer.apple.com/forums/thread/833627
- Verdict: no route for the student's own plan. Developer pays.

## 3. App Intents / Siri AI calling Smooth
- Apple: Siri AI "can get things done across apps with even more systemwide app actions" (newsroom 2026-06). Session 240 "Build intelligent Siri experiences with App Schemas": https://developer.apple.com/videos/play/wwdc2026/240/ . Forum post: "Siri AI can take action directly inside third-party apps without fixed trigger phrases." https://developer.apple.com/forums/thread/833643
- Available: Apple's Siri AI can read Smooth's entities and run its intents (e.g. "what's due this week"), using Apple's model, not the student's Claude/ChatGPT.
- Not found: any statement that Claude/ChatGPT apps can invoke other apps' intents. Session Q&A suggests a system orchestrator does it, not apps driving each other.

## 4. Shortcuts
- Claude app: "Ask Claude" App Intent (iOS 18+), from Siri, Spotlight, Share menu and Shortcuts; "Chain multiple 'Ask Claude' actions together"; uses the default model and counts against the user's usage limit. https://support.claude.com/en/articles/10263469-use-claude-app-intents-shortcuts-and-widgets-on-ios . Not stated: response returned as a Shortcuts output (implied).
- Apple "Use Model": On-Device, Cloud, Cloud Pro, Extension Model; Extension Model "Uses ChatGPT to handle your requests." Only ChatGPT. https://support.apple.com/guide/shortcuts/tpg3vrvwmclv
- Feasible: Smooth exposes a "Get work list" App Intent returning text; student builds Shortcut = Smooth action -> Ask Claude / Use Model (ChatGPT). Runs on student's own plan; Smooth never sees credentials, but the student must assemble/install the shortcut (and Smooth must publish a shareable one).
- (ChatGPT app's own Shortcuts actions: not verified.)

## 5. Share / hand-off
- Claude help: "Select text and use the Share menu to send it directly to Claude." (app's Ask Claude intent). Desktop only: `claude://claude.ai/new?q=` prefills, does not send, ~14,000 char cap. https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link . Mobile deep link: not read.
- Web `claude.ai/new?q=` reportedly broke Oct 2025 (secondhand): https://github.com/anthropics/claude-code/issues/8827
- `chatgpt.com/?q=` works per community reports, unofficial, short length limit: https://simonwillison.net/b/8625 , https://community.openai.com/t/url-query-param-to-open-chat-with-initial-message/64167
- Smooth can use a standard iOS share sheet (UIActivityViewController) to hand text (e.g. work list) to the Claude/ChatGPT app: no official doc beyond the Claude help article above. Output stays in that app.

## 6. Apple's ChatGPT integration
Still ChatGPT-only in Apple surfaces (Use Model "Extension Model" = ChatGPT). No source shows it exposed to third-party apps' code.

## Bottom line
Nothing lets Smooth's own in-app requests bill a student's Claude/ChatGPT plan. Workable: (a) Siri AI/Shortcuts via Smooth App Intents with the student's chosen assistant app on the other end, (b) share-sheet handoff of the work list. Re-check Extensions on a real iOS 27 device before relying on it.

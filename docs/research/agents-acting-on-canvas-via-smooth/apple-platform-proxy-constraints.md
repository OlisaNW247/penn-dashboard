# Apple-platform constraints on an iPhone app acting as an authenticated "proxy" for an external AI agent (as of 2026-10-30)

Method note: developer.apple.com pages are JavaScript-rendered; they were read through Apple's own JSON documentation endpoints (`developer.apple.com/tutorials/data/documentation/...json`), which mirror the public pages. The App Store Review Guidelines page shows "Last Updated: October 16, 2026". Fetched text was passed through a summarising model, so quotes are as returned by that tool, not independently diffed. Several items below are only sourced from Apple Developer Forums threads or third parties; these are labelled.

## 1. Waking the phone: silent push, BGTasks, WKWebView in the background, persistent connections

### Takeaway
Apple's silent push gives about 30 seconds per delivery, is explicitly not guaranteed, is throttled above roughly 2-3 per hour, and is not delivered to a force-quit app. No Apple-sanctioned mode gives a reliable "wake within minutes, do a network round trip and a WKWebView load" path for a non-user-initiated request. PushKit is call-only.

### Cited Findings
- Apple says background pushes "silently wake your app", must use `content-available: 1` with no alert/sound/badge, `apns-priority` 5 and `apns-push-type` background. — [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- Apple says, once delivered, "your app has up to 30 seconds to complete its work" and should call the completion handler as soon as possible. — [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app); also [Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app) ("30 seconds to perform any tasks and call the provided completion handler")
- Apple says "If you send background pushes more frequently than three times per hour, the system imposes rate limitations." — [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- Apple says "don't try to send more than two or three per hour"; "the system may throttle the delivery of background notifications if the total number becomes excessive"; "the system doesn't guarantee their delivery"; "The system treats background notifications as low priority." No numeric "budget" word is used on the page. — [Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- Force quit: Apple's page says "If something force quits or kills the app, the system discards the held notification." — [Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app). Forum/third-party reports state a force-quit app is not woken by silent push until the user reopens it (non-Apple, consistent with Apple line) — [Apple forums 744901](https://developer.apple.com/forums/thread/744901), [forums 760244](https://developer.apple.com/forums/thread/760244), [Braze docs](https://braze.com/docs/developer_guide/platforms/swift/push_notifications/silent)
- A TestFlight forum report of silent push background launch rejected with "pushDisallowed" — user report, not Apple documentation. — [forums 835645](https://developer.apple.com/forums/thread/835645)
- BGAppRefreshTask: "The system decides the best time to launch your background task, and provides your app up to 30 seconds of background runtime." — [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- BGProcessingTask: intended for "periods of low activity, such as overnight when the device charges", "the system decides the best time to launch". The page gives no duration. — [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- BGContinuedProcessingTask (iOS 26.0+): "A task that starts in the foreground and can continue running in the background as needed." Starts only "in response to someone's action, such as tapping a button". Progress is shown in a Live Activity and the person can cancel it. The system may terminate it abruptly and prioritises terminating tasks with minimal progress. GPU use needs the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement. Submission strategy `queue` (default) or `fail`; no numeric limit published ("maximum number of concurrent tasks" only). — [BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask), [Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- WWDC25 session 227 introduces BGContinuedProcessingTask. — [WWDC25-227](https://developer.apple.com/videos/play/wwdc2025/227/) (listed in search; page body not read)
- WKWebView in a suspended/background app: no Apple doc found. Apple Developer Forums answers say pausing is by design ("for the same reasons any app that is suspended no longer gets to execute code"), possibly relaxed "only for a few seconds"; workarounds are hacks. Cordova bug reports show WKWebView JS callbacks not firing correctly on background silent push. — [forums 111247](https://developer.apple.com/forums/thread/111247), [forums 64150](https://developer.apple.com/forums/thread/64150), [Cordova CB-12815](https://issues.apache.org/jira/browse/CB-12815). These are 2016-2018-era threads; treat as old.
- PushKit: "If you are unable to support CallKit in your app, you cannot use PushKit to handle push notifications. Instead, configure your app's push notification support with the User Notifications framework." VoIP apps "must use CallKit". — [PushKit: Responding to VoIP notifications](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit)
- Guideline 2.5.4: "Multitasking apps may only use background services for their intended purposes: VoIP, audio playback, location, task completion, local notifications, etc." — [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- Guideline 2.4.2: apps "may not run unrelated background processes, such as cryptocurrency mining." — [Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### Inferences
- A relay-initiated "fetch this Canvas page now" via silent push is best-effort: a latency of seconds to hours, nothing at all if the user force-quit Smooth, and only a few wake-ups per hour. The agent cannot be told "done in 30 s" with any guarantee.
- 30 s is tight for URLSession plus a hidden WKWebView SSO re-login (the repo's own notes record an 8 s foreground renewal, with Duo prompts taking longer). A URLSession-only fetch with existing cookies fits; a WebView re-login in a background wake is unproven (and this repo's CLAUDE.md records background wakes currently crash).
- PushKit/VoIP and silent-audio/location tricks to keep a socket alive fall outside 2.5.4's "intended purposes" and are rejection risks. (Inference from the policy text; no Apple statement naming this exact pattern was found.)
- BGContinuedProcessingTask does not help for agent-initiated work, because it requires a foreground user tap.

### Gaps
- No Apple text found on whether a WKWebView can load pages inside a BGAppRefreshTask/silent-push launch; only forum evidence.
- No published numeric budget for silent pushes beyond "2-3 per hour"/"three times per hour"; no iOS 26-specific change found.
- Low Power Mode behaviour was not on the fetched Apple page.

## 2. Live Activities push-to-start and push rate limits

### Takeaway
ActivityKit pushes have an undisclosed hourly budget; priority 5 does not count against it; push-to-start can launch a Live Activity (and grants background runtime) on iOS 17.2+/18+, but it requires an alert and visible UI, so it is a notification mechanism rather than a hidden wake channel.

### Cited Findings
- "The system allows for a certain budget of ActivityKit push notifications per hour." No number given. Default priority 10 "counts toward the notification budget"; priority 5 "doesn't count toward the budget"; exceeding may throttle. — [Starting and updating Live Activities with ActivityKit push](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)
- Push-to-start: "When the system receives the ActivityKit push notification on a device, it starts a new Live Activity, wakes up your app, and grants it background runtime to allow you to download assets". Start payload requires an `alert`; not available on iOS 17.1 and earlier; broadcast pushes cannot start a Live Activity. — same page
- `NSSupportsLiveActivitiesFrequentUpdates` Info.plist key enables frequent updates; users can disable them in Settings (`frequentPushesEnabled`). — same page
- Lock Screen: an ended Live Activity stays "for up to four hours" by default. — same page

### Inferences
- A visible Live Activity per agent request is possible but intrusive and unsuited to a student's lock screen for routine fetches; the "background runtime" granted is for asset download, with no stated duration.

### Gaps
- Exact hourly budget number not published; "background runtime" duration after push-to-start not published.

## 3. App Intents (Siri / Shortcuts / Apple Intelligence)

### Takeaway
Apple documents that most intents run quietly in the background and can bring the app forward when needed, but publishes no time limit; developers report ~20-30 s. Whether an intent run from another device works with the phone's Keychain cookies is not documented.

### Cited Findings
- "Most app intents run quietly in the background and deliver results back to the system, but some app intents need to bring your app to the foreground to complete their action." Code in the app bundle "can run in either the foreground or background"; an intent in an App Intents extension "always runs in the background." — [Configuring the runtime behavior of your app intents](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents)
- `supportedModes` lets an intent "run in the background initially but transition your app to the foreground at some point later"; it "is only a suggestion to the system"; `continueInForeground(_:alwaysConfirm:)` errors from an extension. — same page
- `openAppWhenRun` is shown in Apple's sample ("Tell the system to bring the app to the foreground when the intent runs"); intents "run on an arbitrary queue". — [Accelerating app interactions with App Intents](https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents)
- Time limit: Apple documentation gives none. A DTS engineer on the forums confirmed a limit exists; developers measured about 20-30 s (one reported 30 s timeouts on iOS 16.1). Community-observed, not Apple-stated. — [forums 716561](https://developer.apple.com/forums/thread/716561), [forums 720454](https://developer.apple.com/forums/thread/720454), [forums 764501](https://developer.apple.com/forums/thread/764501) (via search summary; thread 720454 body would not load)
- Keychain in background: an item with `kSecAttrAccessibleWhenUnlocked` fails while the device is locked; forum guidance points to `AfterFirstUnlock` for background use. — [forums 692355](https://developer.apple.com/forums/thread/692355), [forums 674831](https://developer.apple.com/forums/thread/674831) (via search summary)
- Apple: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is "recommended for items that need to be accessed by background applications", is unreadable after restart until first unlock. — [kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattrafterfirstunlockthisdeviceonly) (fetched via the `ksecattraccessibleafterfirstunlockthisdeviceonly` JSON path)
- `openAppWhenRun` on a locked device requires unlock (developer report). — [forums 779977](https://developer.apple.com/forums/thread/779977) (via search summary)

### Inferences
- The repo already stores cookies with AfterFirstUnlock-ThisDeviceOnly, so a background-run intent can read them after first unlock. An intent in the app target with a short URLSession fetch fits the ~20-30 s observed window; an SSO re-login does not.
- "Submit my assignment" as an Apple Intelligence/Siri action is technically expressible as an App Intent, but nothing found says Apple Intelligence will invoke third-party intents from a ChatGPT/Claude agent; and a state-changing action should require an explicit confirmation step (the intent system supports confirmation, but I did not verify the API in this session).

### Gaps
- No Apple source on intent time limits, on Mac-to-iPhone intent execution, or on Apple Intelligence invocation of third-party intents in iOS 26 (not researched beyond the above).

## 4. Local network listener on iPhone and Mac

### Takeaway
An iPhone app cannot be a dependable LAN server: listeners stop/fail when the app becomes eligible for suspension. A Mac app can host a local server (it is not suspended like iOS) but the Local Network prompt/entitlement details were not verified.

### Cited Findings
- `NSLocalNetworkUsageDescription` is required for apps that use the local network "directly or indirectly", including Bonjour and "direct unicast or multicast connections to local hosts"; iOS 14+/macOS 11+. — [NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)
- Apple DTS (Quinn) on NWListener: "The system will defunct stuff immediately on suspending your app"; a Bonjour-registered listener "will fail on suspend"; a non-Bonjour listener "simply stops listening" and resumes accepting on resume, but "this is current implementation, not API contract"; "it's best to stop your listener when you become eligible for suspension." Not affected: an app that is backgrounded but not suspended (e.g. playing audio). — [forums 840808](https://developer.apple.com/forums/thread/840808)
- A developer's NWListener server stopped accepting about 15 minutes in despite the Location background mode (observation, not Apple policy). — [forums 772637](https://developer.apple.com/forums/thread/772637)
- MCP spec (version 2025-06-18; check for a newer revision): servers running locally "SHOULD bind only to localhost (127.0.0.1)", MUST validate the `Origin` header, SHOULD authenticate. — [MCP transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)

### Inferences
- A phone LAN listener adds nothing over the relay: the desktop agent would only reach it while Smooth is foregrounded, and the Local Network prompt is a new privacy hurdle. Mac does not face iOS suspension, but the local-network prompt, sandbox `com.apple.security.network.server` entitlement and Mac login-at-boot behaviour were not verified here.

### Gaps
- TN3179 (local network privacy) body would not load; prompt wording and listener-triggers unverified. Mac App Sandbox server entitlements not researched.

## 5. App Store Review Guidelines relevant text (current page, last updated 2026-10-16)

### Takeaway
No guideline names "act on another service's behalf for an AI agent". The closest are 5.1.1(v) (aimed at social networks), 5.1.2(i) (explicit permission, "including with third-party AI"), 5.2.2 (permission from the third-party service), 4.2.7 (remote desktop limits), and 2.5.4/2.4.2 (background use). The Keychain-for-passwords rule is not in the guidelines text I retrieved.

### Cited Findings
- 5.1.1(v): "An app may not store credentials or tokens to social networks off of the device and may only use such credentials or tokens to directly connect to the social network from the app itself while the app is in use." — [Guidelines](https://developer.apple.com/app-store/review/guidelines/). The clause is about social networks; Canvas is an LMS, so its literal application is unclear, but the spirit is "credentials stay on device, used by the app itself, while in use".
- 5.1.1(vi): "Developers that use their apps to surreptitiously discover passwords or other private data will be removed from the Apple Developer Program." — same
- 5.1.2(i): "You must clearly disclose where personal data will be shared with third parties, including with third-party AI, and obtain explicit permission before doing so." Also "you may not use, transmit, or share someone's personal data without first obtaining their permission." — same
- 5.1.1(i): the privacy policy must "Explain its data retention/deletion policies and describe how a user can revoke consent and/or request deletion". 5.1.1(iii): "only collect and use data that is required to accomplish the relevant task." — same
- 5.2.2: "If your app uses, accesses, monetizes access to, or displays content from a third-party service, ensure that you are specifically permitted to do so under the service's terms of use. Authorization must be provided upon request." — same
- 4.2.7 (remote desktop clients that mirror specific software/services): host must be "a personal computer or dedicated game console owned by the user" and "both the host device and client must be connected on a local and LAN-based network"; "Thin clients for cloud-based apps are not appropriate for the App Store." — same. This governs a client that mirrors a host, not an app that executes agent commands, but shows Apple's stance on remote-control architectures is narrow and LAN-bound.
- 4.2 (minimum functionality): app should "include features, content, and UI that elevate it beyond a repackaged website"; 4.2.3(i) "Your app should work on its own without requiring installation of another app to function." — same
- 2.5.2: apps may not "download, install, or execute code which introduces or changes features or functionality of the app". An agent sending free-form scripts/JS to run in the WebView would raise this; fixed, typed actions would not. — same
- 5.4 (VPN): apps offering VPN must use NEVPNManager; there is no analogous network-proxy sanction for general app traffic. — same
- Keychain: Apple's constants page says ThisDeviceOnly items do not migrate to a new device; no guideline text stating "must use Keychain for other services' passwords" was found. — [AfterFirstUnlockThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)

### Inferences
- The biggest review risks are 5.1.2(i) (agent-provider = third-party AI; needs disclosure and consent for any Canvas content passed to ChatGPT/Claude) and 5.2.2 (Canvas/institution terms). Transmitting the session cookie or password off the phone is the line to avoid (consistent with the 5.1.1(v) spirit and with Smooth's current privacy posture).
- Fetched 5.1.1(vi)/(vii)-style text and the 5.1.1(v) account-sign-in text came from a summarising fetch tool; verify wording against the live page before quoting in any submission.

### Gaps
- Guidelines sections 1.x, 3.x, and 5.1.3-5.1.5 not retrieved in detail; no guideline on "automation of another service" located.

## 6. macOS companion and MCP precedents; WebKit and Keychain persistence

### Takeaway
Local stdio/HTTP MCP servers on a Mac are a well-established pattern, but the iPhone's cookies do not travel: ThisDeviceOnly keychain items never sync, so a Mac companion must log in to Canvas itself (its own WKWebView session, persisted by default).

### Cited Findings
- MCP spec 2025-06-18 defines two standard transports, stdio (client launches the server as a subprocess) and Streamable HTTP; "Clients SHOULD support stdio whenever possible." — [MCP transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports) (older revision; later ones may differ)
- Claude Desktop: local stdio servers are declared in `~/Library/Application Support/Claude/claude_desktop_config.json` under `mcpServers`; remote servers are added as Connectors (Streamable HTTP + OAuth); `.mcpb` Desktop Extensions package local servers. Third-party guides, not Anthropic docs; plan availability for custom connectors conflicts across them. — [mcpplaygroundonline guide](https://mcpplaygroundonline.com/blog/how-to-setup-mcp-claude-desktop), [calmara](https://calmara.app/blog/how-to-install-mcp-server-claude-desktop)
- Xcode 26.3 added MCP support; external agents connect via `xcrun mcpbridge` (e.g. `claude mcp add --transport stdio xcode -- xcrun mcpbridge`). Sourced from press/third-party; Apple's own page not found. — [InfoQ](https://infoq.com/news/2026/02/xcode-26-3-agentic-coding), [swiftjectivec](https://swiftjectivec.com/Agentic-Coding-Codex-Claude-Code-in-Xcode/)
- Existing Mac MCP servers: supermemoryai/apple-mcp (Messages, Mail, Notes, Calendar, Reminders, Contacts), krmj22/macos-mcp (EventKit binary + JXA for Notes), FradSer/mcp-server-apple-events, Apple-MCPs reminders on PyPI; they need macOS privacy permissions (Reminders/Calendar, Automation). — [krmj22/macos-mcp](https://github.com/krmj22/macos-mcp), [FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events), [apple-mcp-reminders](https://pypi.org/project/apple-mcp-reminders/), [supermemoryai/apple-mcp via docsearch](https://docsearch.algolia.com/mcp/docs/repo/supermemoryai/apple-mcp). These are community projects; star counts/status not verified.
- `WKWebsiteDataStore.default()` "stores data persistently to disk" and is the default for `WKWebViewConfiguration`; `nonPersistent()` is in-memory. Available macOS 10.11+, iOS 9+. — [WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)
- Keychain: ThisDeviceOnly items "do not migrate to a new device"; and `kSecAttrSynchronizable` items "may not also specify a kSecAttrAccessible value that is incompatible with syncing (namely, those whose names end with ThisDeviceOnly)". iCloud keychain sync applies to items marked synchronizable. — [kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly), [kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable)

### Inferences
- The Mac build would need its own Canvas sign-in (SSO plus Duo at Penn) in its WKWebView; the cookie jar then persists in the default store between launches, while the 24h-rule/renewer logic in this codebase would need to run on the Mac, too. Syncing the iPhone's cookies would require making them synchronizable, which contradicts the ThisDeviceOnly design and the privacy posture; I would not recommend it.
- Desktop agents reach a Mac app most simply through a stdio shim (tiny binary launched by Claude Desktop/Code that talks to the running Smooth Mac app over a local socket), or localhost Streamable HTTP with Origin validation.

### Gaps
- No first-party Anthropic/OpenAI doc was fetched on current local-MCP support in ChatGPT desktop; Apple's Xcode MCP page not located; Mac sandbox/notarization requirements for a bundled stdio helper not researched.

## 7. Precedents for the "phone as authenticated proxy for a cloud agent" pattern

### Takeaway
No credible iPhone precedent found. The closest are Android-only proxy-hosting services and Pushcut's Automation Server, which must stay foregrounded on a dedicated device.

### Cited Findings
- Pushcut Automation Server runs shortcuts from webhooks without user interaction but "only processes requests while the Pushcut app is in the foreground"; its help page recommends a dedicated always-on iOS device. — [Pushcut Automation Server](https://pushcut.io/help/automation_server) (via search summary; page body not fetched)
- Phone-as-residential-proxy services (FalconProxy on Android as a foreground service, ProxyVeil pooled home devices, Proxy4Agent MCP) are Android/desktop, marketing-sourced, and none runs on iPhone. — [Proxy4Agent](https://github.com/Goldentrii/proxy4agent), [mcpmarket ProxyVeil](https://mcpmarket.com/zh/server/proxyveil-1)

### Inferences
- iOS's suspension model (section 1) plausibly explains why the pattern exists on Android but not iOS; this is inference, not stated by any source.

### Gaps
- Not researched: Tailscale/Funnel phone reachability, Apple Continuity/Handoff as precedent, any browser-agent product that executes inside a user's own mobile session. "Nothing credible found" applies only to what the two searches returned.

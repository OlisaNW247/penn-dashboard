# Canvas login → "Stale Request" — session handoff

_Written 2026-08-22. Read this top to bottom before touching anything; it is
short on purpose._

## 1. The problem

In-app Canvas login fails **deterministically**. Penn's Shibboleth IdP returns
its **"Stale Request"** page partway through the SSO chain. Every attempt, no
recovery.

This is Shibboleth's own page, not our UI. (We *also* have a "Canvas login hit
a snag" card of our own — that one is a separate, already-fixed bug. Don't
confuse them. See §5.)

## 2. What is already ruled out — with evidence

Do not re-investigate these. Each was tested, not reasoned about.

| Ruled out | Evidence |
|---|---|
| **The last 3 commits** (`f4f811c`, `6a21ea4`, `470360b`) | Checked out `8ada9c9` — the exact build where login worked hours earlier — rebuilt, **same Stale Request**. |
| **Our error-card latch bug** | Fixed in `8ada9c9`; the card no longer replaces the WebView, and the flag clears on each new navigation. |
| **Purge being incomplete** | `WebsiteDataReset.purgeWebsiteData` uses `allWebsiteDataTypes()` and matches eTLD+1; hints `["upenn","duosecurity","instructure"]` cover the whole chain. |
| **"Reset login data" escape hatch** | User ran it (sweeps all 4 jars incl. `HTTPCookieStorage.shared`). Did not help. |
| **Spoofed user agent** | Retracted after inspection. On iOS 26.6 `LoginUserAgent` emits `…OS 26_6… AppleWebKit/605.1.15 … Version/26.6 Mobile/15E148 Safari/604.1`, which is the correct shape for real iOS Safari — those WebKit/Mobile tokens are genuinely frozen. Not obviously wrong. |

## 3. What is NOT yet known — start here

Two open questions. **Get both answers before writing any code.**

1. **Does Safari in a Private tab also fail?**
   Normal Safari *works*, but that is a confounded result: normal Safari may
   have a live Penn SSO session and skip the IdP handshake entirely. Our
   WebView purges first, so it always does the cold handshake. Private
   Browsing reproduces the cold path.
   - Private Safari works → genuinely WebView-specific. Dig in.
   - Private Safari fails → Penn-side. Stop looking at our code.

2. **Which hop returns Stale Request?** Canvas, the Penn IdP, or Duo?
   Settings → **Copy diagnostics report**. It records the redirect chain and
   the page title that tripped the detector.

   > **2026-08-22:** until now the redirect chain was never actually
   > recorded — `LoginNavigationObserver`'s
   > `decidePolicyFor navigationResponse:` was marked `private`, which
   > excludes it from `@objc` optional-requirement matching, so WebKit never
   > called it and reports contained only "(page title)" lines. Fixed in
   > this commit (**uncompiled** — no toolchain here; needs `swift test` +
   > a rebuild on the Mac). A report copied from a build without this fix
   > cannot answer this question — rebuild first, then reproduce the
   > failure once, then copy the report.

Neither answer had arrived when this session ended.

## 4. Leading hypothesis, if it is WebView-specific

`LoginDataStores` uses `WKWebsiteDataStore(forIdentifier:)` — a persistent but
**non-default, history-free** store. WebKit's Intelligent Tracking Prevention
classifies every domain in a fresh store as a first-ever cross-site visit,
which is the worst possible input for a multi-domain SSO chain (SP → IdP →
Duo → back). `LoginDataStores`' own doc comment already flags this risk in
its rationale for not using `.nonPersistent()`.

Untested. Do not act on it before §3.

## 5. File map for this bug

```
LowHangingFruitUI/
  OnboardingView.swift        CanvasLoginPane (~line 495): purge → WebView → capture
  LoginDataStores.swift       the isolated per-service WKWebsiteDataStore
  WebsiteDataReset.swift      the purge; allWebsiteDataTypes, eTLD+1 match
  LoginNavigationObserver.swift  observe-only delegate; error-title detection
  LoginUserAgent.swift        the Safari UA spoof
  SessionCookieStore.swift    Keychain cookie persistence (load() drops stale)
  DiagnosticsReport.swift     what "Copy diagnostics report" produces
docs/CANVAS_LOGIN_DIAGNOSIS.md, docs/CANVAS_LOGIN_HARDENING.md
```

## 6. Repo state

- Branch: **`claude/lhf-v3-canvas-merge-6msbyo`**, tip `470360b`, pushed.
- **368 tests / 35 suites passing.** `cd LowHangingFruitKit && swift test`.
- `origin/v3` is **fully contained** in this branch (0 commits missing), so
  `git merge --ff-only` works — but **coordinate with Marco first**: his
  `28891ca` sequences six branches into `v3`, and this is 38 commits arriving
  out of that order.
- Everything is committed. Working tree clean.

## 7. Two open items unrelated to this bug

- **Ledger migration never verified on device.** The migrations that *delete*
  the old UserDefaults blobs have never executed. `swift test` structurally
  cannot reach them (no App Group entitlement → fallback paths). Needs
  installing **over a populated app**, not a fresh one.
- **App Store**: Support URL and a hosted privacy policy still needed. The
  contact email is filled (`lowhangingfruit.help@gmail.com`).

## 8. How to run this session

**You are the overseer. Plan, delegate, review. Do not write code yourself.**

Three subagents are defined in `.claude/agents/`:

| Agent | Model | Use for |
|---|---|---|
| `mechanic` | haiku | Fully-specified mechanical work: renames, moving code, greps, boilerplate. Zero judgement calls. |
| `implementer` | sonnet | Real implementation where the *what* is specified but the *how* needs care. |
| `verifier` | sonnet | Read-only review against acceptance criteria. Never edits. |

Cost discipline: **push work down a tier whenever the brief has no judgement
left in it.** If you find yourself writing a brief that says "decide X",
that decision is yours — make it, then delegate the mechanical remainder.

### Briefs must stand alone
Subagents see **none** of your conversation. Every brief needs: the goal and
exact scope (including what not to touch), file paths and current state,
concrete acceptance criteria, and what to report back.

### The rule that matters most here
**A change that has not been compiled is not done.** There is no Swift
toolchain in this container — not for you, not for any subagent. Every report
must say so plainly. This project lost most of a session to
resolved-but-uncompiled Swift being pushed; `swift test` runs only on the
user's Mac.

### Two failure modes this project has actually hit
1. **Whole-side merge resolution.** Taking one side of a conflicted file
   wholesale silently drops the other side's unique work while leaving its
   callers. Cost three rounds of compile errors.
2. **Cross-suite Keychain races.** Tests touching `SessionCookieStore`'s
   `.canvas` item must live in `SessionCookieStoreTests`' single `.serialized`
   suite. Swift Testing parallelises across suites; a second serialized suite
   does not help.

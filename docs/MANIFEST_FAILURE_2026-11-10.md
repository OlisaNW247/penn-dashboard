# Marco's "manifest failed", 2026-11-10

Read-only diagnosis, written 2026-11-10 about 06:00 UTC on
`claude/v11-backend-645aa0`. Nothing was deployed and no Swift was changed.

## The symptom

Marco's iPhone 17 Pro (the 3.4.1 (20) Debug build), course-material sync
summary (`lastCourseKnowledgeSyncSummaryV1`, App Group plist):

- 2026-11-09 22:53 EST (03:53 UTC 2026-11-10): `ok · courses 6 · fetched 1 ·
  partial 5 · docs 195 · manifest failed · uploaded 0 · errors 7 · error
  kinds: pages 5 · assignments 2 · ed: matched 2 · read 2 · restored 0 ·
  dropped 4`
- 2026-11-10 00:50 EST (05:50 UTC), relayed by the v11 builder session: the
  same, with `errors 5 · error kinds: pages 5 · ed notes 0`.
- 2026-11-05: `manifest failed · uploaded 0 · errors 19 · first failure
  other · couldn't read the tabs of 3 canvas course(s): cancel...`

A throwaway user's manifest call succeeds (`deploy-facts.mjs --step 2`).

## What the server saw: both calls answered 200

Function invocation logs (`GET /v1/projects/<ref>/analytics/endpoints/logs`,
source `function_edge_logs`; see the trap below for the query shape), the
phone's address hashed, never printed:

| UTC | function | status | server time | request | response (compressed) | client |
|---|---|---|---|---|---|---|
| 2026-11-10 03:53:21 | `sync` | **200** | 4386 ms | 14330 B | 6108 B | `Smooth/20 CFNetwork/3860.700.1` |
| 2026-11-10 05:45:09 | `agent-snapshot` | 200 | 1298 ms | 15456 B | 71 B | same phone |
| 2026-11-10 05:45:28 | `sync` | **200** | 4517 ms | 14330 B | 6108 B | same phone |

There is one `sync` call per run, the manifest (no upload follows, which is
what `uploaded 0` means). Console logs for that function in the window hold
nothing but `boot`, `shutdown` and one `sync: catalog refresh had 1/1
failure(s)`, which is `TAP 2028`'s Penn Labs lookup (a program site, not a
registrar course; harmless, `refreshCatalog` swallows it by design). No
`internal_error`, no 426 from the version gate, no 5xx.

So the server finished and answered both times, with byte-identical sizes,
which says the answer is deterministic for this phone.

## The server's answer decodes

To rule the payload out, a throwaway anonymous user sent the same request
(the six course summaries exactly as the `courses` rows hold them, so the
upsert wrote nothing new; the server's own 194 live stubs as `documents`;
`client: phone`; all nine `acceptsKinds`; `X-Smooth-Version: 3.4.1`), and the
answer was checked against the phone's strict decoding rules in
`LowHangingFruitKit/Sources/LowHangingFruitKit/Models/BackendWire.swift`
(`SyncManifestResponse.init(from:)`): `coursesFresh` and `serverManifest`
element types, every `CourseCatalogEntry` / `ClassMeeting` /
`CatalogComponent` required field, and `CourseProfileWire`. Everything
lossy by design (`download`, `facts`, `factsCursor`, `examDates`) cannot fail
the decode. Result: HTTP 200 in 4.8 s, `serverManifest` 194, `catalog` 5,
`profiles` 1, `facts` 17 (sent `factsSince: 0`), **no strict-decode
problem**. The user was deleted through `delete-account` (200). The logged
size of that answer was 8220 B compressed for 26417 B raw; Marco's 6108 B
fits the same answer with no new facts (his cursor is past them).

His enrolments (read by course id only): `1799668` TAP 2028, `1946718` and
`1949400` PHYS 0151 (both sites), `1947653` CIS 3990, `1948237` FNAR 0010,
`1949818` CIS 2620; 194 live documents, nowhere near the 1000-row manifest
cap or PostgREST's `max_rows`. Nothing in the manifest path depends on two
sites of one code beyond the catalog join, which answered both correctly.

## So the failure is on the phone, after the bytes arrive or instead of them

`AppState+CourseKnowledge.swift` treats any throw from
`client.syncManifest(...)` as "manifest failed", and
`BackendClient.send` (`LowHangingFruitUI/BackendClient.swift:206`) has
exactly three ways to throw once the server has answered 200:

1. `urlSession.data(for:)` throws (`BackendError.transport`): a timeout
   (60 s, not reached at 4.5 s) or **the calling task being cancelled**.
2. The decoder throws (`BackendError.decoding`); ruled out above unless the
   phone's request differs from the reproduction in a way that changes the
   strict fields, which it should not (they are course-level, not per
   document).
3. A 401 retry that fails; ruled out, the server answered 200.

The reason itself is recorded, `trace.manifestError` (with
`BackendDiagnostics.lastDecodingFailure` for a decode), but only in memory:
the summary line written to the plist says `manifest failed` and nothing
else, and the trace lines that show it (`courseKnowledgeDiagnosticLines`,
`manifest=failed error=…`) are behind `FeatureFlags.profileDiagnostics`,
which is off. So the cause cannot be read off the phone today.

**Best reading of the evidence: cancellation.** The 2026-11-05 run's first
collector failure was literally `couldn't read the tabs of 3 canvas
course(s): cancel…`, URLSession's cancelled error. The rest of the run fits
a cancelled task too: after the manifest, every Canvas call that follows in
the same task throws at once, which is `partial 5 · pages 5` with one course
fetched; and the server keeps working on a request the client has already
abandoned, which is why its log says 200 while the phone says failed. The
course-knowledge sync runs inside `AutoSyncCoordinator.refreshCanvasGrades`,
which the dashboard calls from structured contexts: the launch pass
(`refreshSessionSourcesAtLaunch`) and the five-minute loop both run inside
`ContentView`'s `.task`, which SwiftUI cancels whenever that view leaves the
hierarchy or its identity changes. Not proven: nothing on the server can say
whether the phone hung up.

## The fix, and where it belongs

The phone, not the server. Nothing to change in `sync`.

1. **Record the reason** (one line, the phone session's area because it is
   Swift): put the error case into the summary,
   `manifest failed (transport | decoding: <path> | http <code>)`, from
   `trace.manifestError`, the same words-only rule the summary already
   follows. One more device run then names the cause.
2. **If it is cancellation** (expected): run the course-knowledge sync in a
   task of its own that a view's cancellation cannot reach (an unstructured
   `Task` held by `AppState`, joined by any later caller, the way
   `startSilentCanvasRenewal` / `awaitPendingSilentRenewal` hold the
   renewal), so the launch pass's or the loop's cancellation does not cancel
   the sync. The wrong fix is retrying the manifest: a cancelled task
   cancels the retry too.
3. If it is a decode after all: the detail names the field; make that field
   lossy like `download` and `facts`.

This is Olisa's sync on the phone side (the collector and
`refreshCourseKnowledge`); the change in 2 is a scheduling change around
it, not inside it, but he should see it first.

## Does it block the assignment-PDF pass?

Yes, on Marco's phone. `attachmentPass(cookies:)`
(`AppState+CourseKnowledge.swift:494`) runs only inside the
`manifestSucceeded` branch, after the upload, so it has never run on his
device. It will run on the first sync whose manifest succeeds; nothing in
the pass itself is implicated.

## A trap worth keeping

The Management API's logs endpoint has no per-source tables any more:
`select … from function_edge_logs` answers "Table … does not exist".
Query `from logs where source = 'function_edge_logs'` (or
`'function_logs'` for console output), read columns through
`log_attributes['response.status_code']` and the like, never `select *`,
and pass `iso_timestamp_start` / `iso_timestamp_end` (24 hours at most).
`response.headers.content_length` is the compressed size.

## Aside: a 426 in the same window

At 03:49:47 UTC another install, `Smooth/17` (3.4.0), was refused by `sync`
with 426. That is the update gate doing its job: 3.4.1 has been live since
2026-11-08 22:29 UTC (public iTunes lookup, read 2026-11-10) and the
`update-manifest` floor is 3.4.1. Not related to Marco's failure.

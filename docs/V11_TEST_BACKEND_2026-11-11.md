# v11 backend, tested hostile (2026-11-11)

A session's test of the live agent connection (`agent-auth` v10, `mcp` v9,
`agent-snapshot` v6, the connector front `smooth-agent.vercel.app`, the
`agent-drafts` bucket) on 2026-11-11 between 23:02 and 00:10 UTC. The source
it read is `v11` at `ee653d9`. Every probe ran against production with
throwaway anonymous users, each deleted through `delete-account`; Marco's
rows were never read or touched. Nothing was deployed.

Production `agent-auth` v10 serves a `/reviewer` route that `ee653d9` does
not have (another session's connector-listing work, deployed at 21:39 UTC).
So production is not exactly the source read here; nothing below depends on
that route.

## Findings, by severity

| # | Severity | Finding | Fixed? |
|---|---|---|---|
| 1 | **High** | Production `delete-account` is v13 of 2026-10-22, older than the agent connection: account deletion (and so Canvas disconnect) leaves every open draft's file and every staged upload in Storage. | Code was already right; the runbook gap that caused it is fixed (`deploy-agent.mjs` now deploys `delete-account`). **Needs a deploy.** |
| 2 | **High** | Behind the front, `/authorize` and `/register` are limited per *Vercel egress address*, not per student: one bucket for the whole school. 60 requests an hour from anyone blocks every student's sign-in. | Fixed in code (front hands the address over with a shared secret). **Needs two secrets and two deploys.** |
| 3 | **Medium** | A PUT to the signed upload URL after the upload ended answers 200 and stores the file under an id no row names. The object survived the opt-out and `delete-account`, and nothing ever removes it. | Fixed in code (stray sweep at begin, finish and opt-out). Needs a deploy. Residual below. |
| 4 | Low | `file_name: ".."` accepted (reached the phone as the name Canvas would get); `mime_type` unchecked (CR/LF or 5,000 characters failed inside Storage with its own message echoed to the agent; any other string is stored). | Fixed in code. Needs a deploy. |
| 5 | Low | The 20-open-draft cap overshoots under concurrency: 70 simultaneous proposals made **25**. PROTOCOL said "by one". | Not fixed (design: needs a database-side check). PROTOCOL corrected. |
| 6 | Low | `Retry-After: 60` on a fixed one-hour window: a client that honours it is refused for up to 59 more minutes, and every retry counts. A browser hitting the `/authorize` limit sees raw JSON. | Not fixed (design). PROTOCOL says so. |
| 7 | Low | An authorization code replayed after a successful redemption is refused, but the tokens from the first redemption stay valid (RFC 6749 §4.1.2 says SHOULD revoke). | Not fixed (design question). |
| 8 | Low | Two simultaneous refreshes of one refresh token: one wins and the reuse detection then revokes the whole connection, the winner's new pair included. A client that retries a refresh after a lost response loses its connection. | Not fixed (design: a grace window is the usual answer, and weakens reuse detection). |
| 9 | Info | `mcp` has no rate limit of any kind; a connection can call tools as fast as it likes. | Not fixed (design). |
| 10 | Info | `mcp`'s SDK `onerror` logs `e.message` unfiltered (seen empty in 24 h of logs); tool exceptions return their raw message to the agent. | Not fixed. |
| 11 | Info | Supabase's own edge log records each request URL with its query, so `status?p=<pending id>&go=1` and `/authorize`'s `state`/`code_challenge` are in the edge log. None is a credential (the pending id is useless without the browser's nonce cookie); no token, code, nonce or cookie appears anywhere. | Nothing to fix in our code. |
| 12 | Info | Each `agent-e2e.mjs` run leaves one registered client; revoked connections are never swept, so a client named by one is never swept either. | Not fixed. |

Everything else answered exactly as `backend/PROTOCOL.md` says: about 220
checks, listed below.

## 1. `delete-account` in production predates the agent connection (High)

**Evidence.** The Management API's function list, read 23:20 UTC:
`delete-account v13 2026-10-22T16:08Z`; the agent cleanup in
`deleteUserData` (`_shared/db.ts`) and `removeUserDraftObjects`
(`_shared/agentDrafts.ts`) was written on 2026-11-09 and 2026-11-10.
`deploy-agent.mjs` deployed only `agent-auth`, `mcp`, `agent-snapshot`.
Measured: a throwaway with one open file draft (2,000 bytes) and one staged
upload (a PUT of 20,000 bytes) called `delete-account` (HTTP 200). Every
`agent_*` row went (the tables cascade from `auth.users`), and **both Storage
objects stayed** (`storage.objects` before 2, after 2). An earlier user's
stray staged object (finding 3) survived its `delete-account` the same way.
`docs/PRIVACY.md` promises the drafts are deleted when the student
disconnects Canvas or deletes the account, so production breaks that promise
for files.

**Fix.** The code on the branch is right; it was never deployed.
`AGENT_FUNCTIONS` in `backend/scripts/deploy-agent.mjs` now ends with
`delete-account`, so the agent runbook redeploys the function whose agent half
changes with the agent code. Deploying `delete-account` from `v11` also ships
every other `_shared/db.ts` change since 2026-10-22; read that diff first.
Objects already left behind by real deleted accounts cannot exist yet (the
bucket held 0 objects when this run began).

## 2. One rate-limit bucket for every student behind the front (High)

**Evidence.** Rate keys are `<route>:<sha256 of the address>`. One bogus
`/authorize` through the front with `x-forwarded-for: 203.0.113.91`, one
straight to `supabase.co` with `x-forwarded-for: 203.0.113.92`: neither
spoofed address got a row. The direct one was counted under my own IPv4
address; the front one under a third hash that was neither my IPv4 nor my
IPv6. Three more through the front (two spoofed IPv4, one plain IPv6 curl)
all landed in that same bucket, and a later front request landed in a
second, also foreign, hash. So Supabase's gateway rewrites
`x-forwarded-for` to the connecting address, and through the front that is
Vercel's egress, a small pool shared by every student. The spoof is
harmless; the sharing is not. `/register` and the `/token` ip ceiling share
too (the ceiling is 1,200, so only `/authorize` and `/register` bind).

**What it means.** PROTOCOL's "60 per ip (the student's own browser)" was one
bucket per Vercel egress address. Today's traffic is low enough that the
limit has not bitten, but anyone can send 60 requests an hour to
`smooth-agent.vercel.app/functions/v1/agent-auth/authorize` and no student
can sign in until the window ends. This test deliberately did not do so:
the 61-hit test went straight to `supabase.co`, my own address's bucket.

**Fix (written, tested, not deployed).** The front (`connector-front/main.ts`)
reads Vercel's own `x-forwarded-for` (Vercel overwrites it with the real
client) and, when `CLIENT_IP_SECRET` is set, sends it to `agent-auth` routes
as `x-smooth-client-ip` with `x-smooth-front-secret`; it never passes either
header from a caller. `agent-auth`'s `clientIP` believes the address only when
the secret matches `LHF_FRONT_CLIENT_IP_SECRET` (hashes compared in constant
time). Without the secrets nothing changes. To turn it on: one random value,
set as `LHF_FRONT_CLIENT_IP_SECRET` on the Supabase project and as
`CLIENT_IP_SECRET` for `connector-front/deploy.sh`, then deploy `agent-auth`
and the front. The wrong fix would be trusting `x-smooth-client-ip` without
the secret: a direct caller could then pick a fresh bucket per request. Tests:
`agentAuthHandler.test.ts` (the secret moves a request into its own bucket, a
wrong or absent secret falls back, a direct caller cannot choose a bucket),
`connectorFront.test.ts` (the header pair goes only to `agent-auth`, only
with the secret, spoofed copies dropped).

## 3. A late PUT leaves an object nothing removes (Medium)

**Evidence.** `begin_file_upload` (30,000 bytes), PUT (200), a second PUT (400
`409 Duplicate`, as designed), `finish_file_upload` (draft made, staging
removed), then a **third PUT to the same URL: 200**. `storage.objects` then
held `<user>/uploads/<upload id>/p.pdf` with no `agent_uploads` row. After
`agent-snapshot` `delete` (opt-out) it was still there; after
`delete-account` it was still there (finding 1). I removed it by hand. A
3 MB PUT to the same URL was refused 413 by the bucket's size limit.

**Cause.** Supabase's signed upload URL lives about two hours and cannot be
revoked; the upload ends at finish, at a replacing begin, or after 30
minutes. The opt-out removed staged objects by row, and `agent_sweep_expired`
deletes rows only, so nothing could find the object. The same path leaves the
staged object of an upload that simply expires (the SQL sweeper deletes its
row, Storage keeps the file).

**Fix (written, tested, not deployed).** `UploadStore.removeStrayStaged`
lists `<user>/uploads/`, reads which of those ids still have a row, and
removes the rest. The listing comes first, so a folder whose row is read
afterwards can only be missing because the upload ended. `UploadService` runs
it, best effort, after every begin and every finish, and the Postgres store's
`deleteAll` (the opt-out) runs it after deleting the rows, which removes every
staged object. Tests in `agentUploads.test.ts`. With the sweep turned off, the
end-to-end test fails.

**Residual.** A stray made after the student's last upload stays until the
next upload, the opt-out or account deletion (once finding 1 is deployed). So
does an expired upload's staged object for a student who never uploads again.
Closing that needs a periodic job that walks the bucket, which an Edge Function
sweep one `/authorize` in fifty is too weak for.

## 4. File names and mime types (Low)

`propose_submission` with `file_name: ".."` made a draft. The Storage path
was sanitized to `<user>/<draft>/file`, so there was no traversal, but
`file_name` reached the phone as `..`. `mime_type: "text/html\r\nX-Evil: 1"`
and a 5,000-character `mime_type` were refused only by the Storage client
("Invalid header value: …", "Invalid Content-Type header"), whose message
went back to the agent; any well-formed string, `text/html` included, was
stored for the phone. Now `fileNameProblem` refuses names that are only dots
or spaces or carry control characters, and `mimeTypeProblem` requires
`type/subtype` in RFC 6838 token characters, at most 127. Both apply to
`propose_submission` and `begin_file_upload` (`agentTools.ts`;
`mcpHandler.test.ts`).

## 5. The draft cap under concurrency (Low)

22 sequential proposals: 20 made, then "too many open drafts". 70 at once on
an empty list: **25 made, 25 open**. The cap is a count and then an insert,
so every request that counts before the 20th insert lands gets in. The phone
lists at most 50, which no API path reached. The agent is the student's own,
so this is clutter rather than abuse. The fix belongs in Postgres (an insert
that counts under a per-user advisory lock, or a trigger) and was left as a
design item.

## What was tested, and how

Harness: Node scripts in the session's scratchpad, copied with their raw
JSON results to the shared notes folder (`v11-hostile-probes/`). They reuse
`agent-e2e.mjs`'s parsers: a scripted OAuth client plus a throwaway phone,
and the Management API for database reads and logs. Sign-ins went straight
to `supabase.co` for `/authorize` and `/status`, so the front's shared bucket
(finding 2) was spent by 8 requests at most. Everything else went through
the front.

**OAuth server (all as PROTOCOL says).** Wrong `code_verifier` gives
`invalid_grant` and burns the code (the right verifier after it is also
refused). A reused code is `invalid_grant` (finding 7). A code exchanged
after 61.5 s is `invalid_grant`. A wrong `redirect_uri` at `/token` is
`invalid_grant` and burns the code. So does another client's `client_id`
and a foreign `resource`; a trailing slash on `resource` is accepted.
Foreign `resource` at `/authorize` is a 302 `invalid_target` with `state`
and `iss`. Missing `state` is allowed, and the redirect then carries none. A
513-character `state`, `plain`, a missing challenge, and
`response_type=token` are each a 302 with the right error. A scope naming
only unknown things is `invalid_scope`. An unregistered `smc_` id, an
unregistered redirect, and an unverified redirect plus another error all get
the 400 page, never a redirect. A loopback redirect on another port is
accepted (RFC 8252); one with an extra query is refused. CIMD: an
unreachable host, a private-looking name, an HTML page, `http:` and an IP
literal are each the 400 page in 166-363 ms. Refresh reuse in both orders: an
old token after one rotation, and a grandparent after two, each give
`invalid_grant` and kill the newest pair (the access token gets 401). Two
simultaneous refreshes give one 200 and one 400 (finding 8). Refresh with
another `client_id` is refused without burning the token. A wider scope is
`invalid_scope`. Narrowed to `read`, `propose_submission` answers "cannot
propose drafts". A foreign `resource` is `invalid_target`. Revoking the
access token gives 200 `{}`, `mcp` 401, and the refresh still works.
Revoking the refresh token gives `mcp` 401 and refresh 400; junk gets
200 `{}`. `/status` with a wrong nonce, and an unknown id, are 403; `go=1`
while pending is `not_approved`; `go=1` twice is 302 then 409
`already_issued`; `go=1` after the five minutes (approved in time) is 400
`expired`. Approve after expiry is 404, and the poll then says `expired`.
`deny` and `approve` by a user who never looked up are 404. Two concurrent
approves by the same student give one 200 and one 409 `already_decided`.
Two students who both looked up: only the last to look up can approve (last
lookup wins, as designed). A wrong match number gives `approved:false,
reason:match`, then `denied`, then a 404 retry. `/phone` lookup with a wrong
code: 404 twenty times, 429 `slow_down` with `Retry-After: 60` on the 21st,
and the limit is applied before the code's shape is checked. `/phone` with
no JWT is 401, an unknown action is 400, and revoking a foreign connection
id gives `revoked:false`. `/token` with `grant_type=password` is
`unsupported_grant_type`; JSON and over 16 KB are `invalid_request`; error
answers carry `no-store` and `Pragma: no-cache`. `/register` refused
`javascript:`, http off loopback, a fragment, `client_secret_basic`, 11 URIs,
non-JSON, userinfo and a custom scheme. A `client_name` of `<img src=x
onerror=…>` is escaped on the authorize page and returned as text by
`lookup` (the phone draws text).

**MCP tools (all as PROTOCOL says, apart from findings 3 and 4).** A
120,000-character query, a course not enrolled, a hostile `kind` and
`page: 1e15` give "no matches". A throwaway is enrolled in nothing, so the
huge-page and `since` paths return before any query; huge `since` values
were read in the code (`new Date(since * 1000)` would throw a `RangeError`
above about 8.6e12 for an enrolled student, surfacing as a tool error), not
run. Page 0, page 2^60, days 0 and 366, and an unknown `view` are each a
validation `isError`; days 365 is fine; an unknown tool is JSON-RPC -32602.
`get_assignment`, `propose_submission` and `append_file_chunk` against
another student's ids say "no such assignment" or "no such upload". Body
100,001, note 2,001, a name with `/` or `\` or 201 characters, `http:` and
`javascript:` urls, base64 of 1,572,865 bytes, invalid and unpadded base64
are each `isError`. `begin`: sha256 of 63 or non-hex characters, a total over
the cap and a total of 0 are refused; at the cap it plans 96 chunks. Chunk
indexes 96, 100 (the 101st chunk) and -1 are out of range; a short non-last
chunk, a chunk of 16,385 bytes and a wrong checksum are refused. A second
begin replaces the first. A chunk resent with other bytes replaces the
original, and finish then refuses the whole-file sha256 and keeps the chunks;
after fixing it, finish makes the draft, and a second finish says "no such
upload". A missing chunk is named by index. PUT twice gives 200 then 409. A
PUT of the wrong size is refused at finish naming both sizes and deletes the
object, so a corrected PUT then works. Finish after the 30 minutes was read
in the code, not waited out: `live()` refuses "upload expired" and removes
the row and object. `Accept` without `text/event-stream` gives 406; malformed
JSON gives 400 -32700; a 4.5 MB body gives 413 (the SDK's limit, before any
tool); `Origin: http://…` and `Origin: null` give 403; GET gives 405 `Allow:
POST`; a batch is answered; an unknown well-shaped token is 401 with the
same challenge words; a refresh token as bearer is 401; `/mcp/anything` is
404.

**Drafts from the phone side (all as PROTOCOL says, apart from finding 5).**
proposed to seen is 200; seen to seen is 409; `proposed` as a target is
400; seen to declined is 200; declined to submitted or seen is 409.
`submitted` without an id, with a 65-character id, with attempt 1001 or 1.5
is 400; `failed` without, or with a 65-character `error_class`, is 400.
Another student's draft or an unknown id is 404; a 65-character or
non-string id is 400. Three concurrent decisions on one draft give exactly
one 200 and two 409. `draft_status` of another student's draft says "no such
draft". A signed file URL answers 200, then 400 at 121.5 s. Opt-out
mid-upload revokes the token (finish then answers 401) and removes uploads
and drafts, but not the late-PUT object (finding 3).

**Rate limits and the sweeper.** `/authorize` straight to `supabase.co`: the
61st hit in the window is 429 `{"error":"slow_down"}`, `Retry-After: 60`,
`no-store`, `application/json` (findings 2 and 6). `token-code`: five 400s
then 429 with `Retry-After: 60`. `lookup`: 429 at 21. `approve`'s limit of 10
is real: an early run of this harness met it, which is why every sign-in
here used a fresh user. `agent_sweep_expired` (read in
`20261110090000_agent_uploads.sql`) deletes pending rows two minutes past
expiry, tokens a day past, rate rows a day old, registered clients 30 days
old that no connection or pending row names, and expired uploads (rows
only, finding 3). It ran twice in the 24 hours ("agent-auth: swept N"),
and the two pending rows there at the start were gone at the end.
`sql-check.sh` (OrbStack) applied all 20 migrations, found all four agent
migrations idempotent, and passed `rls.test.sql`, `agent_connection`,
`agent_hardening` and `agent_uploads`.

**RLS and the service role (35 checks, no deviation).** With the publishable
key, and with a throwaway's JWT, a GET of each of the nine `agent_*` tables
is refused or empty, and no insert succeeds. `rpc/agent_rate_check` and
`rpc/agent_sweep_expired` are refused. Storage: listing `agent-drafts`,
uploading into one's own prefix, the public URL and the bucket settings are
all refused. Read with the Management API: RLS is on for every `agent_*`
table, there are no grants and no policies for `anon` or `authenticated`,
the bucket is private with a 1,572,864-byte limit and no mime list, and
`anon` and `authenticated` have no `execute` on `agent_*` functions.

**The front.** All ten discovery paths (root RFC 8414/9728 forms, with and
without the suffix and trailing slash, plus the function-relative ones)
answer 200 with our issuer and resource and `max-age=300`. Unknown
well-known paths, `/random`, `/functions/v1/sync` and
`/functions/v1/delete-account` are 404, and so is a POST to a well-known
path. The landing page is 200 HTML with a CSP, `X-Frame-Options: DENY` and
the MCP URL. Path tricks (`%2e%2e`, `%2F..%2F`, `..%2F`) never reached
another function (404 from the front, or "Requested function was not found"
from Supabase). A 7 MB body is refused 413 with or without `Content-Length`,
but by **Vercel** (`FUNCTION_PAYLOAD_TOO_LARGE`, its 4.5 MB limit), so the
front's own 6 MB check never fires. A 3 MB chunked body to `/token` reaches
`agent-auth`, which answers `invalid_request`. Hop-by-hop request headers
(`Connection`, `Upgrade`, `TE`) do no harm. Through the front, error pages
are `text/html` again with the `X-Smooth-*` markers stripped, and `mcp`'s
401 keeps `WWW-Authenticate` with CORS exposing it. `x-forwarded-for`
spoofing: see finding 2.

**Logs (24 hours to 00:05 UTC, `function_edge_logs` and `function_logs`).**
From 23:24 UTC on 2026-11-10 to 21:40 UTC there was no non-2xx answer at
all (the first eight hours held 42 agent requests; the later windows were
read for non-2xx only). From 21:40 to 21:42 came the e2e and reviewer session's expected
refusals: `mcp` 401 after a revoke, `token` 400, `agent-snapshot` 400, 409
and 404, and `reviewer` 403 and 303. Then two `mcp` 401s at 22:47 and 22:55,
which look like a real client's expired access token followed by a refresh.
From 23:02 on, everything was this test: 150 non-2xx in all, each matching
a probe above. `function_logs` for the agent functions hold only outcome
codes and counts (`agent-auth error: token_invalid_grant (400)`,
`agent-snapshot: drafts n=N`, `agent-auth: swept N`). A search of every
agent log line and edge line for the shapes `smt_a_`/`smt_r_`/`smt_c_`,
`smd_`, `smu_`, `eyJ…` (a JWT), `sb_secret`, an `sa_` nonce and a user code
found none. Every `console.*` in `agent-auth`, `mcp`, `agent-snapshot` and
`_shared/agent*.ts` was read: each logs a fixed code, a count or an error
class, except `mcp`'s SDK `onerror` (finding 10). `version.ts` logs the
manifest fetch's error message, which carries no request data. The logs
API allows a few queries a minute (`ThrottlerException`) and caps a query
at 1,000 rows, so the reads were split into 2-hour windows.

## Cleanup

Every throwaway user was deleted through `delete-account` (HTTP 200 each; 0
auth users created after 23:02 UTC remain). The four Storage objects that
findings 1 and 3 left were deleted by hand with the project's secret key;
the bucket holds 0 objects again. The six `agent_clients` this run
registered (named "Smooth hostile probe", "Smooth hostile probe 2" and the
`<img…>` test) were deleted. Left in place: 60 `agent_rate_limits` rows
keyed by hashes of my address, the throwaways' user ids, their connections
and their codes. The sweeper removes them a day after their windows opened.
My address's `/authorize` bucket on `supabase.co` is at its limit until
about 00:03 UTC (direct calls only; the front is a different bucket). Also
still there: 13 `agent_clients` from earlier `agent-e2e.mjs` runs (12
"Smooth e2e", 1 "probe"), of which 12 are named by nothing and go 30 days
after creation, at a sweep. Marco's rows (2 connections, 2 drafts, 2
snapshots) were the same at the end as at the start.

## Gates on the branch

`deno task test` 898 passed (889 + 9 new), `deno task check` clean, `node
--test backend/scripts/*.test.mjs` 51 passed, `backend/scripts/sql-check.sh`
green. No Swift was touched.

## To deploy, when Marco says so

1. Read the `_shared/db.ts` diff since 2026-10-22, then deploy
   `delete-account` (finding 1). This fixes a broken privacy promise; it is
   the urgent one.
2. Deploy `agent-auth` and `mcp` (findings 3 and 4; `agent-snapshot` too,
   since the opt-out's sweep lives in the shared upload store). `node
   backend/scripts/deploy-agent.mjs` does all four now, then `agent-e2e.mjs`.
3. For finding 2: one random secret, set as `LHF_FRONT_CLIENT_IP_SECRET`
   (Supabase) and passed as `CLIENT_IP_SECRET` to `connector-front/deploy.sh`.
   Deploy `agent-auth` first (it ignores the headers until the secret is
   set), then the front. Check that two different addresses get two
   `authorize:` rows.

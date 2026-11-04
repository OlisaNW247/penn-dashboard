# Extension end-to-end harness

Runs the real extension (the MV3 files in `src/`, no build) in real headless
Chromium against a local fake of Ed Discussion, Canvas, Gradescope and the
Smooth backend.

    npm run e2e                      # loads this directory
    node e2e/run.mjs /path/to/unzipped-store-zip

It needs only node built-ins, Playwright and `/usr/bin/openssl`. Generated
certs and the Chromium profile go to a scratch directory under `/tmp`, never
into the repo. Takes about 30 seconds.

## What it proves

- The Ed content script lifts `localStorage.authToken` and the worker keeps it
  in `chrome.storage.session` only.
- A collection run (started by token arrival, and again by the `sync` alarm)
  reads `/api/user` and pages each course's threads (offsets 0, 100, 200 for a
  250-thread class, one page for a short class) with `x-token` and no cookie.
- Only the right threads become `ed` documents (announcements, pinned, staff
  posts that are not questions; private and anonymous dropped), with the
  expected ids, URLs, header line, Eastern posting day and plain-text bodies.
- The upload's `fullySyncedCourses` lists them, the summary reads `ed: "in"`,
  and the token is in no supabase request and no `chrome.storage.local` key.
- After a browser restart (session storage gone) a run records `ed: "none"`,
  and visiting Ed again starts a run on its own.

## What it cannot prove

A real Ed login. Ed's actual page, its real token lifecycle, its real API
responses and real Canvas/Penn sign-in are all replaced by guesses modelled on
`test/fixtures/ed/`. Where the fake guesses (timestamp offset style, user
roles, response envelopes for the backend functions) is commented in
`fakeWorld.mjs`.

## Never point it at real hosts

Chromium is started with `--host-resolver-rules` mapping the real hostnames to
127.0.0.1, `--ignore-certificate-errors` and `--no-proxy-server`. Do not reuse
that launch configuration for anything else, and do not add real hostnames or
real credentials to the fake.

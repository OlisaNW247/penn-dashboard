# McGraw Hill reader: briefs for Marco

Each brief is a job that needs a Mac, a real browser or a phone on a cable.
Olisa relays them; Marco's own Claude session reads them. Each one stands
alone: it says what to do, the exact commands, and what to paste back.

Context for every brief: the owners decided on 2026-11-02 to build a reader
of a student's own McGraw Hill Connect (later ALEKS) assignments, on the
phone only, behind a remote kill switch that is off (`ROADMAP.md` → Next →
McGraw Hill; `reports/McGraw Hill access for Smooth.md`). The work is on the
branch `feature/mcgraw-hill-reader`, draft PR into `v8`. Never merge it,
never push to `v8`, never touch the `update-manifest` branch.

---

## Brief 1 (2026-11-02): record what McGraw Hill Connect actually serves

**Status: waiting for an account.** On 2026-11-02 Olisa said neither he nor
Marco has a McGraw Hill class this term. He is asking a friend who does.
This brief runs once that friend agrees to sit with Marco (or to run it
themselves on their own Mac with this repo).

### Why

Nothing in this repo knows McGraw Hill's endpoints. The only technical
evidence is one hobby project's code comments (a long-lived `ERIGHTS`
cookie on `newconnect.mheducation.com`, a five-minute `MH_TOKEN` JWT minted
by `POST /caas/heclr/coire/refreshToken`, an assignments API taking that JWT
as a Bearer header plus a `person_xid`). Treat all of it as a rumour. The
reader's client will be written against what this brief records, and
nothing else, so the shapes matter more than any value.

### The rule that overrides everything below

**Never commit, paste or write down a cookie value, a token, a JWT, a
`person_xid`, an email address, a real name, a score, a section id, a course
id or any other id. Real assignment titles are not needed either.** Replace
every id with `<id>`, every value with its type (`string`, `number`,
`bool`, `ISO date string`, `null`, `object`, `array`). Header and cookie
*names* are wanted; their *values* never. The friend signs in themselves;
nobody else sees or types their password. If in doubt, leave it out.

### Who and what

- A student with a real, current Connect section (the friend), signed in to
  Canvas at canvas.upenn.edu (or their own school's Canvas) in **desktop
  Chrome** on a Mac.
- The friend opens Connect **from Canvas, the way they normally do** (a
  McGraw Hill link in the course's navigation, a module, or an assignment).
- DevTools open before the click: View → Developer → Developer Tools →
  Network tab, "Preserve log" ticked, filter **Fetch/XHR** (and look at
  **Doc** for the launch hops).

### Steps

1. **The Canvas side first** (same browser, before launching Connect). Open
   `https://canvas.upenn.edu/api/v1/courses/<course id>/assignments?include[]=submission`
   for the McGraw Hill class (the course id is in the class's Canvas URL;
   do not write it down). Chrome shows JSON. For **one** Connect assignment
   only, note:
   - `submission_types` (expected `["external_tool"]`)
   - the **host** of `external_tool_tag_attributes.url` (host only, e.g.
     `connect.mheducation.com`; not the path, not the query)
   - whether `external_tool_tag_attributes.new_tab` is true
   - whether `due_at` is set (yes/no)
   - `submission.workflow_state`, and whether `submitted_at` is null
   If the friend has one Connect item not yet done and one already done,
   note both. The point: does Canvas ever record a finished Connect item as
   submitted?
2. **The launch.** Clear the Network log. Click the McGraw Hill link in
   Canvas. Record, in order, the document hops (Doc filter): each
   **host + path** with ids as `<id>`, and whether the click opened a **new
   tab or window** (and whether Connect said anything like "launched in a
   new tab"). Note the URL Connect finally lands on (host + path).
3. **The assignment list.** On Connect's student to-do or assignments page
   (reportedly `newconnect.mheducation.com/student/todo`), find the Fetch/XHR
   request whose response lists the assignments. Record:
   - method, host and path (ids as `<id>`), and the query parameter
     **names**
   - how it is authenticated: the **names** of request headers that look
     like auth (`Authorization: Bearer …` → write `Authorization: Bearer
     <jwt>`), and the **names** of cookies sent (Network → the request →
     Cookies tab; names only)
   - the JSON response's **field names and types** for one assignment,
     values replaced by types, nested objects shown as nested. Mark which
     field is the title, the due date (and its format), and **the field
     that says done/submitted/completed, with every value it took** across
     the items on screen (e.g. `status: "COMPLETED" | "NOT_STARTED" |
     "IN_PROGRESS"`)
   - whether any field links back to the Canvas assignment (an LTI resource
     link id, a Canvas assignment id): field name and type only
   - whether the list holds work the instructor did **not** deploy to
     Canvas (anything on Connect's list that the Canvas assignments page in
     step 1 does not show; a yes/no and a count is enough)
4. **The token, if there is one.** If a request mints a short-lived token
   (look for `refreshToken`, `token`, `auth` in the path), record its method,
   host and path, the names of the cookies it sends, and the **names and
   types** of its response fields. If the response is a JWT, the claim
   **names** inside it (paste the JWT into nothing; decode it locally with
   the command below and copy only the key names):
   ```bash
   # in Terminal; paste the token when asked, nothing is saved or sent
   read -rs JWT && JWT="$JWT" python3 -c 'import os,json,base64; p=os.environ["JWT"].split(".")[1]; p+="="*(-len(p)%4); c=json.loads(base64.urlsafe_b64decode(p)); print(sorted(c.keys()), "lifetime_s:", c.get("exp",0)-c.get("iat",0))'; unset JWT
   ```
   Also note how long the token says it lives (`exp - iat` in seconds) and
   the cookie expiry of the long-lived session cookie (Application tab →
   Cookies; the **Expires** column only, as "session" or a duration).
5. **Sign-in and bot checks.** In a private window, open
   `https://newconnect.mheducation.com/student/todo` without signing in.
   Record where it redirects (host + path), what the sign-in page's URL is,
   and whether there is a CAPTCHA, a "verify you are human" page, or a
   Cloudflare/Akamai interstitial. Do not sign in there unless the friend
   wants to.
6. **Idle life.** Leave the signed-in Connect tab idle for as long as is
   practical (an hour is enough; longer is better), then reload the to-do
   page. Did it still load, or ask to sign in? Rough is fine.

### What to write

Create `docs/mcgraw-hill/RECON.md` on the branch with this shape, filled in
(types and names only, as above):

```markdown
# McGraw Hill Connect recon (date, who ran it: "Marco with a friend")

## Canvas side (one Connect item)
- submission_types:
- external_tool_tag_attributes.url host:
- new_tab:
- due_at set: yes/no
- not done: workflow_state = ..., submitted_at null: yes/no
- done (if seen): workflow_state = ..., submitted_at null: yes/no
- after the due date (if seen):

## Launch from Canvas
1. host/path
2. ...
- new tab or window: yes/no
- lands on: host/path

## Assignment list request
- METHOD https://host/path?param_names
- auth headers (names): ...
- cookies sent (names): ...
- response shape:
  ```json
  { "field": "type", ... }
  ```
- title field:
- due date field and format:
- done field and its values:
- link back to Canvas (field, type), if any:
- items Connect lists that Canvas does not: yes/no, count

## Token
- METHOD https://host/path, cookies sent (names), response fields (names/types)
- JWT claim names:
- token lifetime (seconds):
- session cookie lifetime:

## Sign-in and bot checks
- signed-out redirect:
- sign-in page:
- CAPTCHA / challenge: yes/no, which

## Idle
- still signed in after N minutes: yes/no
```

### Commands (on the Mac, in the repo)

```bash
git fetch origin feature/mcgraw-hill-reader
git checkout feature/mcgraw-hill-reader
git pull origin feature/mcgraw-hill-reader
# write docs/mcgraw-hill/RECON.md, then check it holds nothing it must not:
grep -nE 'eyJ[A-Za-z0-9_-]{10,}|[0-9]{6,}|@[A-Za-z0-9-]+\.|ERIGHTS=|Bearer [A-Za-z0-9]' docs/mcgraw-hill/RECON.md \
  && echo "STOP: something above looks like a token, an id or an email" || echo "clean"
git add docs/mcgraw-hill/RECON.md
git commit -m "Record McGraw Hill Connect recon (names and types only)"
git push -u origin feature/mcgraw-hill-reader
```

Only push when the grep prints `clean` (or every line it prints has been
checked by eye and is not a secret, for example a field *named*
`personXid`).

### What to paste back to Olisa

One line: "RECON.md pushed at <commit>", plus the answers to three
questions, which decide the reader's road:

1. Did the launch from Canvas open a new tab or window? (If yes, a hidden
   in-app launch may not work, and the reader would need a visible McGraw
   Hill sign-in.)
2. Does Canvas ever show the finished Connect item as submitted
   (`submitted_at` not null)?
3. Was there a CAPTCHA or bot challenge anywhere?

### If no desktop session is possible

If the friend can only do this on their phone, say so to Olisa instead of
improvising. The fallback is a DEBUG-only recon screen in the app (a WebView
that records request paths and JSON key paths, compiled out of Release),
which is not written yet because it would need the friend's Canvas sign-in
on Marco's phone. It will be written as brief 2 if needed.

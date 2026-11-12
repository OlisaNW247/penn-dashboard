-- Smooth ambassador system. Additive only: the existing `scans` table is
-- never altered. Back up D1 before applying (see README "Deploy").

-- The existing table, created here only so a fresh local database has it.
CREATE TABLE IF NOT EXISTS scans (
  poster TEXT PRIMARY KEY,
  total INTEGER NOT NULL
);

-- Private roster. Contact details live here and nowhere else.
-- Two ids on purpose. `token` is the credential: it opens the private page,
-- the app's plan and the write routes, and it is shown only to the ambassador
-- and the founders. `ref` is public: it is printed in share links, posted in
-- group chats and encoded in sticker QR codes, so anyone can see it. It only
-- identifies the ambassador for counting a link open and opens nothing
-- private. They are generated independently, so seeing one says nothing
-- about the other.
CREATE TABLE IF NOT EXISTS ambassadors (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  token TEXT NOT NULL UNIQUE,          -- secret, in the private link /a/{token}
  ref TEXT NOT NULL UNIQUE,            -- public, in /r/{ref}/s/... and /r/{ref}/p/...
  name TEXT NOT NULL,
  school TEXT NOT NULL,                -- key from worker/catalog.js
  contact TEXT NOT NULL DEFAULT '',    -- phone, ig handle, whatever they use
  title TEXT NOT NULL DEFAULT 'founding ambassador',
  status TEXT NOT NULL DEFAULT 'invited', -- invited | active | paused | left
  paused_until TEXT,                   -- ISO date, reminders skip until then
  notes TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- One row per ambassador link open (poster scan or share link).
-- Poster scans via /r/{ref}/p/{design} ALSO increment `scans` so the public
-- dashboard stays complete.
CREATE TABLE IF NOT EXISTS amb_hits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ambassador_id INTEGER NOT NULL REFERENCES ambassadors(id),
  kind TEXT NOT NULL,                  -- poster | link
  key TEXT NOT NULL,                   -- design, or channel key
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS amb_hits_amb_ts ON amb_hits(ambassador_id, ts);

-- One row per scan on ANY route from now on, so "this week" can be computed
-- per school and design. Totals stay in `scans`; this is a log.
CREATE TABLE IF NOT EXISTS scan_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  poster TEXT NOT NULL,                -- the `scans.poster` key
  ambassador_id INTEGER,               -- null for printed/legacy codes
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS scan_events_poster_ts ON scan_events(poster, ts);

-- What ambassadors did: poster drops and posts.
CREATE TABLE IF NOT EXISTS activity (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ambassador_id INTEGER NOT NULL REFERENCES ambassadors(id),
  kind TEXT NOT NULL,                  -- drop | post
  design TEXT,                         -- for drops
  channel TEXT,                        -- for posts
  place TEXT NOT NULL DEFAULT '',
  copies INTEGER NOT NULL DEFAULT 1,
  note TEXT NOT NULL DEFAULT '',
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS activity_amb_ts ON activity(ambassador_id, ts);

-- Onboarding checklist progress.
CREATE TABLE IF NOT EXISTS checklist (
  ambassador_id INTEGER NOT NULL REFERENCES ambassadors(id),
  step TEXT NOT NULL,
  done_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (ambassador_id, step)
);

-- Feedback to the founders.
CREATE TABLE IF NOT EXISTS feedback (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ambassador_id INTEGER NOT NULL REFERENCES ambassadors(id),
  body TEXT NOT NULL,
  seen INTEGER NOT NULL DEFAULT 0,
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Reminders the founders sent, so nobody gets chased.
CREATE TABLE IF NOT EXISTS reminders (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ambassador_id INTEGER NOT NULL REFERENCES ambassadors(id),
  kind TEXT NOT NULL,                  -- digest | moment:<key> | welcome
  replied INTEGER NOT NULL DEFAULT 0,
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

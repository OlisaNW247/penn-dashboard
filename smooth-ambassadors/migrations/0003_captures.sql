-- Captures and suggestions. Additive only. Every statement is IF NOT EXISTS, so
-- the Worker can run this file on each cold start the way it runs 0001 and 0002.
--
-- `captures` holds two kinds of screenshot an ambassador sends from their page
-- or the app: 'feed' (a still from a recording of their school's anonymous
-- feed, up to 16 per recording, all sharing one `batch` id with `seq` giving
-- the order) and 'result' (one screenshot of how a post did, with the numbers
-- the ambassador typed). As in 0002 the image is base64 TEXT and not a BLOB,
-- because D1 hands a BLOB back in different shapes across runtimes, and its
-- type is decided by sniffing the bytes, never taken from the client.
CREATE TABLE IF NOT EXISTS captures (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ambassador_id INTEGER NOT NULL REFERENCES ambassadors(id),
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  kind TEXT NOT NULL,                  -- 'feed' or 'result'
  batch TEXT NOT NULL DEFAULT '',      -- feed: one recording's id, result: empty
  seq INTEGER NOT NULL DEFAULT 0,      -- feed: the still's position in its recording
  platform TEXT NOT NULL DEFAULT '',   -- result: fizz, sidechat, yikyak or other
  style TEXT NOT NULL DEFAULT '',      -- result: question, list, pitch or other
  upvotes INTEGER,                     -- result: optional, null when not given or not a number
  views INTEGER,
  note TEXT NOT NULL DEFAULT '',
  mime TEXT NOT NULL,                  -- decided by sniffing the bytes
  image TEXT NOT NULL,                 -- base64 of a JPEG, PNG or WebP
  seen_at TEXT                         -- set when a founder marks it seen
);
CREATE INDEX IF NOT EXISTS captures_amb_kind_ts ON captures(ambassador_id, kind, ts);
CREATE INDEX IF NOT EXISTS captures_amb_batch_seq ON captures(ambassador_id, batch, seq);

-- A post a founder wants one ambassador to try, with an optional reply to
-- leave under it. Shown on that ambassador's page and in their plan.json.
CREATE TABLE IF NOT EXISTS suggestions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ambassador_id INTEGER NOT NULL REFERENCES ambassadors(id),
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  text TEXT NOT NULL,
  reply TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS suggestions_amb_ts ON suggestions(ambassador_id, ts);

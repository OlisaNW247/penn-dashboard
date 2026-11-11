-- Poster ideas: an image, a note, or both, sent by an ambassador from their
-- page or the app. Additive only. Every statement is IF NOT EXISTS, so the
-- Worker can run this file on each cold start the way it runs 0001.
--
-- `image` is base64 TEXT and not a BLOB on purpose. D1 hands a BLOB back in
-- different shapes across runtimes (an array of numbers, an ArrayBuffer, a
-- Uint8Array), while a string is unambiguous everywhere. The limit on a stored
-- value is 2 MB either way, and the Worker caps an image at 600 KB decoded
-- (about 800 KB as base64), well inside it.
CREATE TABLE IF NOT EXISTS poster_ideas (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ambassador_id INTEGER NOT NULL REFERENCES ambassadors(id),
  ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  note TEXT NOT NULL DEFAULT '',
  mime TEXT,                           -- decided by sniffing the bytes, never by the client
  image TEXT,                          -- base64 of a JPEG, PNG or WebP, or null for a note-only idea
  seen_at TEXT                         -- set when a founder marks it seen
);
CREATE INDEX IF NOT EXISTS poster_ideas_amb_ts ON poster_ideas(ambassador_id, ts);

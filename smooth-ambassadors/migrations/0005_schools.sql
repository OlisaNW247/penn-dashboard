-- Schools created at request time (2026-11-24), so a new school needs no deploy
-- and no app update. Built-in schools (the host's Map) are unchanged and always
-- win an id collision; a row here with a built-in's id is ignored, which is how
-- a school is later promoted by a rebuild without moving anyone.
CREATE TABLE IF NOT EXISTS schools (
  id TEXT PRIMARY KEY,                 -- also the code prefix: {id}-{14 chars}
  name TEXT NOT NULL,
  canvas_host TEXT,                    -- only an allowlisted host no other school has, else NULL
  created_ts TEXT NOT NULL,
  created_by INTEGER                   -- the inviting ambassador's id, NULL for a founder
);

-- Who may invite, and who invited whom. NULL can_invite means "yes for a UPenn
-- ambassador (the founders), no for everyone else".
-- NOT idempotent in SQLite: sites/entry.js runs the two statements below one by
-- one and ignores "duplicate column name"; wrangler d1 migrations runs them once.
ALTER TABLE ambassadors ADD COLUMN can_invite INTEGER;
ALTER TABLE ambassadors ADD COLUMN invited_by INTEGER;

-- Install counts per school. Additive only; every statement is IF NOT EXISTS so
-- the Worker can run this file on each cold start the way it runs 0001 to 0003.
--
-- The app sends one anonymous count after a student connects Canvas: the Canvas
-- host of their school and whether the install is new. Apple reports no
-- downloads by school, so this is the only way to know. It is a tally and
-- nothing else: no row per install, no id, no address, no user agent.
CREATE TABLE IF NOT EXISTS installs (
  host TEXT NOT NULL,
  day TEXT NOT NULL,                   -- UTC date, YYYY-MM-DD
  kind TEXT NOT NULL,                  -- 'new' or 'existing'
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (host, day, kind)
);

-- One random salt per UTC day. Together with install_seen it only exists to cap
-- repeats from one network, and it is deleted once the day is over, which makes
-- the buckets below unrecoverable: nobody can hash an address and look it up.
CREATE TABLE IF NOT EXISTS install_salts (
  day TEXT PRIMARY KEY,
  salt TEXT NOT NULL
);

-- bucket = hex SHA-256 of salt | address | host. Counts posts, never who.
CREATE TABLE IF NOT EXISTS install_seen (
  day TEXT NOT NULL,
  bucket TEXT NOT NULL,
  n INTEGER NOT NULL,
  PRIMARY KEY (day, bucket)
);

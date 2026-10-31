-- Durable, minimal coordination state. No music files, account credentials or user data.
CREATE TABLE IF NOT EXISTS control (
  id INTEGER PRIMARY KEY CHECK(id=1),
  paused INTEGER NOT NULL DEFAULT 1 CHECK(paused IN (0,1)),
  updated_at INTEGER NOT NULL
);
INSERT OR IGNORE INTO control(id,paused,updated_at) VALUES(1,1,0);

CREATE TABLE IF NOT EXISTS jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  role TEXT NOT NULL CHECK(role IN ('mp3-playback','mp3-sources','mp3-ui','mp3-qa','mp3-integration')),
  cycle INTEGER NOT NULL CHECK(cycle>=0),
  state TEXT NOT NULL CHECK(state IN ('queued','leased','done','blocked')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0),
  available_at INTEGER NOT NULL,
  lease_id TEXT,
  last_lease_id TEXT,
  lease_expires INTEGER,
  commit_sha TEXT,
  outcome TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(role,cycle)
);
CREATE INDEX IF NOT EXISTS idx_jobs_claim ON jobs(state,available_at,id);
CREATE INDEX IF NOT EXISTS idx_jobs_leases ON jobs(state,lease_expires);

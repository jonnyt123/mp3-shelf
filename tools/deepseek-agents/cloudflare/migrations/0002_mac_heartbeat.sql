-- Add non-secret Mac runner presence/status for the free dashboard.
ALTER TABLE control ADD COLUMN runner_last_seen INTEGER;
ALTER TABLE control ADD COLUMN runner_stage TEXT NOT NULL DEFAULT 'offline';

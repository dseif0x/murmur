-- Small key/time settings. classify_since: transcripts received before this
-- are never sent to the classification worker (set when classification is
-- switched on without backfill, cleared when it's switched off).
CREATE TABLE settings (
    key text PRIMARY KEY,
    at  timestamptz NOT NULL
);

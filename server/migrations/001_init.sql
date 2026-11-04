-- Transcripts: one row per utterance a device heard (text only, no audio).
-- The id is generated on the device, so retried uploads are idempotent.
CREATE TABLE transcripts (
    id           uuid PRIMARY KEY,
    device       text        NOT NULL,
    mode         text        NOT NULL DEFAULT 'always', -- always | ptt
    started_at   timestamptz NOT NULL,
    ended_at     timestamptz NOT NULL,
    text         text        NOT NULL,
    language     text,
    received_at  timestamptz NOT NULL DEFAULT now(),
    -- a worker run takes a batch by setting these; the result consumer sets
    -- processed_at when the run's result is stored
    claimed_by   text,
    claimed_at   timestamptz,
    processed_at timestamptz
);
CREATE INDEX transcripts_started ON transcripts (started_at);
CREATE INDEX transcripts_pending ON transcripts (started_at) WHERE processed_at IS NULL;
-- 'simple': no stemming, works the same for German and English
CREATE INDEX transcripts_fts ON transcripts USING gin (to_tsvector('simple', text));

-- Items the model found: reminders, todos, notes, events.
CREATE TABLE items (
    id           bigserial PRIMARY KEY,
    kind         text        NOT NULL, -- reminder | todo | note | event
    title        text        NOT NULL,
    details      text        NOT NULL DEFAULT '',
    due_at       timestamptz,          -- due date, or an event's start
    ends_at      timestamptz,          -- an event's end
    status       text        NOT NULL DEFAULT 'open', -- open | done | dismissed
    -- what was said, kept after the transcripts themselves expire
    evidence     text        NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    created_by   text        NOT NULL DEFAULT 'llm' -- llm | user
);
CREATE INDEX items_status ON items (status, kind);

-- Which transcripts an item came from (no foreign key: transcripts expire).
CREATE TABLE item_sources (
    item_id       bigint NOT NULL REFERENCES items (id) ON DELETE CASCADE,
    transcript_id uuid   NOT NULL,
    PRIMARY KEY (item_id, transcript_id)
);
CREATE INDEX item_sources_transcript ON item_sources (transcript_id);

-- History of every change to an item, by the model or by hand.
CREATE TABLE item_events (
    id      bigserial PRIMARY KEY,
    item_id bigint      NOT NULL REFERENCES items (id) ON DELETE CASCADE,
    at      timestamptz NOT NULL DEFAULT now(),
    actor   text        NOT NULL, -- llm | user
    action  text        NOT NULL, -- created | updated | completed | reopened | dismissed
    run_id  text,
    detail  jsonb
);
CREATE INDEX item_events_item ON item_events (item_id, at);

-- Worker runs that did inference.
CREATE TABLE runs (
    id                text PRIMARY KEY,
    started_at        timestamptz NOT NULL,
    finished_at       timestamptz NOT NULL DEFAULT now(),
    model             text        NOT NULL DEFAULT '',
    transcripts       int         NOT NULL DEFAULT 0,
    items_created     int         NOT NULL DEFAULT 0,
    items_updated     int         NOT NULL DEFAULT 0,
    prompt_tokens     int         NOT NULL DEFAULT 0,
    completion_tokens int         NOT NULL DEFAULT 0,
    error             text        NOT NULL DEFAULT ''
);

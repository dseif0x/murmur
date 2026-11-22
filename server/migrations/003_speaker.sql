-- Who said it, when the device's speaker detection is on: "me" (the voice
-- enrolled on the device) or "speaker 2", "speaker 3", ... within a
-- conversation. NULL: no speaker detection.
ALTER TABLE transcripts ADD COLUMN speaker text;

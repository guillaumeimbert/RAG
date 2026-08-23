-- 0003_chunk_quality.sql — defense in depth on chunk text.
--
-- Empty / whitespace-only chunks are dropped before insert (html_text
-- discards empty blocks; chunk discards empty accumulated text). This
-- constraint enforces the invariant at the database too, so a regression in
-- the extraction or chunking path can never store a junk row that would
-- silently pollute vector retrieval.
--
-- The check is `text ~ '[^[:space:]]'` ("contains at least one non-whitespace
-- character"), NOT `btrim(text) <> ''`: btrim only strips spaces (0x20), so
-- a tab- or newline-only chunk would slip past it. The POSIX [:space:] class
-- covers spaces, tabs, newlines, carriage returns, form feeds and vertical
-- tabs.
--
-- Idempotent AND corrective: an earlier draft used a space-only btrim check
-- under the same constraint name, so if that version is present it is dropped
-- and the regex check is installed. A fresh database and an already-migrated
-- database both end with the regex constraint.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chunks_text_nonempty'
    ) THEN
        ALTER TABLE chunks DROP CONSTRAINT chunks_text_nonempty;
    END IF;
    ALTER TABLE chunks
        ADD CONSTRAINT chunks_text_nonempty CHECK (text ~ '[^[:space:]]');
END $$;
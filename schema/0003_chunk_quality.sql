-- 0003_chunk_quality.sql — defense in depth on chunk text.
--
-- Empty / whitespace-only chunks are dropped before insert (html_text
-- discards empty blocks; chunk discards empty accumulated text). This
-- constraint enforces the invariant at the database too, so a regression in
-- the extraction or chunking path can never store a junk row that would
-- silently pollute vector retrieval. Idempotent: a fresh DB and an already
-- migrated DB both come out with the constraint.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chunks_text_nonempty'
    ) THEN
        ALTER TABLE chunks
            ADD CONSTRAINT chunks_text_nonempty CHECK (btrim(text) <> '');
    END IF;
END $$;
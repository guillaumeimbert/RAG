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
-- Idempotent AND corrective AND data-safe:
--   * an earlier draft used a space-only btrim check under the same
--     constraint name; if that version is present it is dropped;
--   * ADD CONSTRAINT validates the stronger check against EVERY existing
--     row, so a database migrated under the old check (which admitted
--     tab/newline-only chunks) would otherwise fail here and roll back.
--     Those rows are whitespace-only junk with no content to preserve (the
--     chunker discards empty text, so they can only come from a regression),
--     so they are removed before the constraint is installed. On a fresh or
--     already-clean database this deletes nothing.
-- A fresh database and an already-migrated (old or new) database both end
-- with the regex constraint and no whitespace-only rows.
DO $$
DECLARE
    n_removed integer;
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chunks_text_nonempty'
    ) THEN
        ALTER TABLE chunks DROP CONSTRAINT chunks_text_nonempty;
    END IF;

    DELETE FROM chunks WHERE NOT (text ~ '[^[:space:]]');
    GET DIAGNOSTICS n_removed = ROW_COUNT;
    IF n_removed > 0 THEN
        RAISE NOTICE
            '0003_chunk_quality: removed % whitespace-only chunk row(s)',
            n_removed;
    END IF;

    ALTER TABLE chunks
        ADD CONSTRAINT chunks_text_nonempty CHECK (text ~ '[^[:space:]]');
END $$;

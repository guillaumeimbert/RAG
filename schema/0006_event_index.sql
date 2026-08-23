-- 0006_event_index.sql — key 13G/13D ownership events by XML row ordinal,
-- not by (filer, subject, class).
--
-- A 13G/13D filing can legitimately contain multiple events with the same
-- (filer, subject, class): the same stake reported under different vote
-- types, or multiple class holdings that share a class name. The old UNIQUE
-- constraint (accession, filer_cik, subject_cik, class) collapsed those rows
-- to one, and the ingest's INSERT ... ON CONFLICT DO UPDATE errored with
-- "cannot affect row a second time". The true identity of an event is its
-- position in the filing, so the UNIQUE constraint is now
-- (accession, event_index), where event_index is the 0-based event ordinal.
--
-- Idempotent and safe on both a fresh (post-0001) database and a database
-- holding rows written under the old key:
--   * adds event_index if absent;
--   * back-fills a deterministic per-accession ordinal for any pre-existing
--     rows;
--   * swaps the UNIQUE constraint to (accession, event_index).
DO $$
DECLARE
    has_event_index boolean;
    ukey_name text;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_attribute
         WHERE attrelid = 'ownership_events'::regclass AND attname = 'event_index'
    ) INTO has_event_index;

    IF NOT has_event_index THEN
        ALTER TABLE ownership_events ADD COLUMN event_index INT NOT NULL DEFAULT 0;
        RAISE NOTICE '0006_event_index: added column ownership_events.event_index';

        -- Back-fill a deterministic per-accession ordinal for pre-existing
        -- rows. The old UNIQUE constraint made (accession, filer_cik,
        -- subject_cik, class) unique, so this ordering is total per
        -- accession and yields a unique 0-based ordinal for the new
        -- constraint. Rows later force-re-ingested under the new code are
        -- rewritten with the true event ordinal.
        UPDATE ownership_events e
           SET event_index = x.rn
          FROM (
            SELECT ctid,
                   ROW_NUMBER() OVER (
                     PARTITION BY accession
                     ORDER BY filer_cik, subject_cik, class
                   ) - 1 AS rn
              FROM ownership_events
          ) x
         WHERE e.ctid = x.ctid;
    END IF;

    -- Swap the UNIQUE constraint to (accession, event_index), idempotently:
    -- drop the current UNIQUE constraint (whatever it is named) and re-add
    -- the new one. The re-add is a no-op when the constraint is already the
    -- new one.
    SELECT conname INTO ukey_name
      FROM pg_constraint
     WHERE conrelid = 'ownership_events'::regclass AND contype = 'u'
     LIMIT 1;
    IF ukey_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE ownership_events DROP CONSTRAINT %I', ukey_name);
        RAISE NOTICE '0006_event_index: dropped unique constraint %', ukey_name;
    END IF;
    ALTER TABLE ownership_events ADD CONSTRAINT ownership_events_accession_event_index_key
        UNIQUE (accession, event_index);
    -- The default is only for the ADD COLUMN back-fill; drop it so future
    -- inserts must carry an explicit ordinal.
    ALTER TABLE ownership_events ALTER COLUMN event_index DROP DEFAULT;
    RAISE NOTICE '0006_event_index: unique constraint is now (accession, event_index)';
END $$;
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
-- holding rows written under the old key. Each step is a no-op when it has
-- already been applied, so re-running never locks or reindexes a table that
-- is already correct:
--   * adds event_index if absent;
--   * back-fills a deterministic per-accession ordinal for any pre-existing
--     rows;
--   * drops the specific legacy UNIQUE constraint
--     (accession, filer_cik, subject_cik, class) only when it is present,
--     and adds (accession, event_index) only when it is not already present.
DO $$
DECLARE
    has_event_index boolean;
    legacy_ukey text;
    new_ukey text;
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

    -- Drop the specific legacy UNIQUE constraint
    -- (accession, filer_cik, subject_cik, class), only if it is present.
    -- Targeting the constraint by its columns (not "any unique constraint")
    -- keeps this safe if other UNIQUE constraints exist on the table.
    SELECT conname INTO legacy_ukey
      FROM pg_constraint c
     WHERE c.conrelid = 'ownership_events'::regclass AND c.contype = 'u'
       AND (SELECT array_agg(a.attname::text ORDER BY k.ord)
              FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_attribute a
                ON a.attrelid = c.conrelid AND a.attnum = k.attnum)
            = ARRAY['accession', 'filer_cik', 'subject_cik', 'class'];
    IF legacy_ukey IS NOT NULL THEN
        EXECUTE format('ALTER TABLE ownership_events DROP CONSTRAINT %I', legacy_ukey);
        RAISE NOTICE '0006_event_index: dropped legacy unique constraint %', legacy_ukey;
    END IF;

    -- Add the new UNIQUE constraint (accession, event_index), only if it is
    -- not already present.
    SELECT conname INTO new_ukey
      FROM pg_constraint c
     WHERE c.conrelid = 'ownership_events'::regclass AND c.contype = 'u'
       AND (SELECT array_agg(a.attname::text ORDER BY k.ord)
              FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_attribute a
                ON a.attrelid = c.conrelid AND a.attnum = k.attnum)
            = ARRAY['accession', 'event_index'];
    IF new_ukey IS NULL THEN
        ALTER TABLE ownership_events ADD CONSTRAINT ownership_events_accession_event_index_key
            UNIQUE (accession, event_index);
        RAISE NOTICE '0006_event_index: unique constraint is now (accession, event_index)';
    END IF;

    -- The NOT NULL DEFAULT was only for the ADD COLUMN back-fill; drop it so
    -- future inserts must carry an explicit ordinal. Guarded so a re-run is
    -- a no-op once the default is gone.
    IF EXISTS (
        SELECT 1 FROM pg_attribute
         WHERE attrelid = 'ownership_events'::regclass AND attname = 'event_index'
           AND atthasdef
    ) THEN
        ALTER TABLE ownership_events ALTER COLUMN event_index DROP DEFAULT;
    END IF;
END $$;
-- 0005_position_index.sql — key 13F holdings by XML row ordinal, not by
-- (cusip, class, prnamt_type).
--
-- A 13F information table can legitimately contain multiple rows with the
-- same (cusip, class, SH/PRN type): the same security held in separate lots,
-- by the filer and other managers, as puts and calls, with different
-- discretion. The old primary key (accession, issuer_cusip, class,
-- prnamt_type) collapsed those rows to one, and the ingest's
-- INSERT ... ON CONFLICT DO UPDATE errored with "cannot affect row a second
-- time" (or silently dropped them when de-duplicated). The true identity of
-- a holdings row is its position in the information table, so the primary
-- key is now (accession, position_index), where position_index is the
-- 0-based XML row ordinal. The SEC put/call and other-manager flags are also
-- captured (they were not parsed before).
--
-- Idempotent and safe on both a fresh (post-0001) database and a database
-- holding rows written under the old key:
--   * adds position_index / put_call / other_manager if absent;
--   * back-fills a deterministic per-accession ordinal for any pre-existing
--     rows (rows written under the old key carry no meaningful ordinal; a
--     unique one is enough for the new key to be valid — a forced re-ingest
--     rewrites them with the true XML row ordinal);
--   * swaps the primary key to (accession, position_index).
DO $$
DECLARE
    has_position_index boolean;
    pkey_name text;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_attribute
         WHERE attrelid = 'holdings'::regclass AND attname = 'position_index'
    ) INTO has_position_index;

    IF NOT has_position_index THEN
        ALTER TABLE holdings ADD COLUMN position_index INT NOT NULL DEFAULT 0;
        ALTER TABLE holdings ADD COLUMN put_call TEXT NOT NULL DEFAULT '';
        ALTER TABLE holdings ADD COLUMN other_manager TEXT NOT NULL DEFAULT '';
        RAISE NOTICE '0005_position_index: added position_index / put_call / other_manager';

        -- Back-fill a deterministic per-accession ordinal for pre-existing
        -- rows. The old key made (accession, issuer_cusip, class,
        -- prnamt_type) unique, so this ordering is total per accession and
        -- yields a unique 0-based ordinal for the new key. Rows later
        -- force-re-ingested under the new code are rewritten with the true
        -- XML row ordinal.
        UPDATE holdings h
           SET position_index = x.rn
          FROM (
            SELECT ctid,
                   ROW_NUMBER() OVER (
                     PARTITION BY accession
                     ORDER BY issuer_cusip, class, prnamt_type
                   ) - 1 AS rn
              FROM holdings
          ) x
         WHERE h.ctid = x.ctid;
    END IF;

    -- Swap the primary key to (accession, position_index), idempotently:
    -- drop the current primary key (whatever it is named) and re-add the
    -- new one. The re-add is a no-op when the key is already the new one.
    SELECT conname INTO pkey_name
      FROM pg_constraint
     WHERE conrelid = 'holdings'::regclass AND contype = 'p'
     LIMIT 1;
    IF pkey_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE holdings DROP CONSTRAINT %I', pkey_name);
        RAISE NOTICE '0005_position_index: dropped primary key %', pkey_name;
    END IF;
    ALTER TABLE holdings ADD PRIMARY KEY (accession, position_index);
    -- The default is only for the ADD COLUMN back-fill; drop it so future
    -- inserts must carry an explicit ordinal.
    ALTER TABLE holdings ALTER COLUMN position_index DROP DEFAULT;
    RAISE NOTICE '0005_position_index: primary key is now (accession, position_index)';
END $$;
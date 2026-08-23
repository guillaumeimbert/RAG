-- 0004_halfvec_hnsw.sql — index the half-precision mirror of the embedding.
--
-- 0001 creates a generated column
--     embedding_hv halfvec(N) GENERATED ALWAYS AS (embedding::halfvec) STORED
-- and an HNSW index on it. Databases created before that migration have the
-- full-precision `embedding vector(N)` column but no mirror and no halfvec
-- index, so at 2560 dims (pgvector's HNSW caps [vector] at 2000) vector
-- retrieval runs as a sequential scan.
--
-- This migration back-fills the mirror and the index on an existing database:
--   * adds the generated `embedding_hv` column (the value is derived from
--     `embedding`; a stored generated column requires a one-time table
--     rewrite on a populated table — expected for a migration);
--   * drops `chunks_embedding_hnsw` only if it is the old full-precision
--     (vector-column) index — an old 0001 created that only when the
--     dimension was <= 2000;
--   * creates the HNSW index on the halfvec mirror when the dimension is
--     within the halfvec HNSW limit (4000).
--
-- Idempotent: on a fresh (post-0004) database every step is a no-op. The
-- dimension is read from the existing `embedding` column, so it matches
-- whatever 0001 created (2560 for the reference stack).
DO $$
DECLARE
    dim integer;
BEGIN
    SELECT atttypmod INTO dim
      FROM pg_attribute
     WHERE attrelid = 'chunks'::regclass AND attname = 'embedding';

    IF dim IS NULL THEN
        RAISE EXCEPTION '0004_halfvec_hnsw: chunks.embedding not found; run 0001 first';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute
         WHERE attrelid = 'chunks'::regclass AND attname = 'embedding_hv'
    ) THEN
        EXECUTE format(
            'ALTER TABLE chunks ADD COLUMN embedding_hv halfvec(%s) '
            'GENERATED ALWAYS AS (embedding::halfvec) STORED', dim);
        RAISE NOTICE '0004_halfvec_hnsw: added generated column embedding_hv halfvec(%)', dim;
    END IF;

    -- Replace a pre-0004 index built on the full-precision [embedding]
    -- column with the halfvec one; leave an already-halfvec index in place.
    IF EXISTS (
        SELECT 1 FROM pg_indexes
         WHERE indexname = 'chunks_embedding_hnsw'
           AND indexdef NOT ILIKE '%embedding_hv%'
    ) THEN
        DROP INDEX chunks_embedding_hnsw;
        RAISE NOTICE '0004_halfvec_hnsw: dropped old vector-column index chunks_embedding_hnsw';
    END IF;

    IF dim <= 4000 THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS chunks_embedding_hnsw
                   ON chunks USING hnsw (embedding_hv halfvec_cosine_ops)';
    ELSE
        RAISE NOTICE '0004_halfvec_hnsw: dimension % > 4000: skipping HNSW index (pgvector halfvec limit)', dim;
    END IF;
END $$;

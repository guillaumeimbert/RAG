-- 0004_halfvec_hnsw.sql — index the half-precision EXPRESSION of the embedding.
--
-- pgvector's HNSW caps [vector] at 2000 dims but [halfvec] at 4000; the
-- reference stack (2560) falls in between, so a full-precision [embedding]
-- cannot be indexed directly. We index a half-precision EXPRESSION of it,
-- (embedding::halfvec(N)), which avoids storing a duplicate mirror column
-- (an earlier revision of this migration used a generated embedding_hv
-- column; this revision drops it). Full precision stays in [embedding]; the
-- search query orders by the SAME halfvec expression so HNSW is used, then
-- reranks the candidates with the full-precision embedding (exact).
--
-- Idempotent and safe on both a fresh (post-0001) database and a database
-- created under the old generated-column revision:
--   * drops the generated embedding_hv column if it exists (a stored
--     generated column requires a one-time table rewrite — expected when
--     migrating an old database; a no-op on a fresh one);
--   * drops chunks_embedding_hnsw only if it is NOT a halfvec expression
--     index (i.e. it is the old generated-column or full-vector index);
--   * builds the expression index with the actual dimension read from the
--     embedding column (the expression index requires the dimension typmod).
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

    IF EXISTS (
        SELECT 1 FROM pg_attribute
         WHERE attrelid = 'chunks'::regclass AND attname = 'embedding_hv'
    ) THEN
        ALTER TABLE chunks DROP COLUMN embedding_hv;
        RAISE NOTICE '0004_halfvec_hnsw: dropped generated column embedding_hv';
    END IF;

    -- Replace an index that is not the halfvec expression index (the old
    -- generated-column or full-vector index) with the expression index; an
    -- existing halfvec expression index is left in place.
    IF EXISTS (
        SELECT 1 FROM pg_indexes
         WHERE indexname = 'chunks_embedding_hnsw'
           AND indexdef NOT ILIKE '%::halfvec%'
    ) THEN
        DROP INDEX chunks_embedding_hnsw;
        RAISE NOTICE '0004_halfvec_hnsw: dropped old index chunks_embedding_hnsw';
    END IF;

    IF dim <= 4000 THEN
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS chunks_embedding_hnsw
               ON chunks USING hnsw ((embedding::halfvec(%s)) halfvec_cosine_ops)',
            dim);
        RAISE NOTICE '0004_halfvec_hnsw: HNSW index on (embedding::halfvec(%))', dim;
    ELSE
        RAISE NOTICE '0004_halfvec_hnsw: dimension % > 4000: skipping HNSW index (pgvector halfvec limit)', dim;
    END IF;
END $$;
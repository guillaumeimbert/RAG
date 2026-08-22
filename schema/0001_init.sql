-- 0001_init.sql — initial schema (runs automatically on first DB init)
--
-- One row per text chunk of one SEC filing. Embeddings come from an
-- OpenAI-compatible server (vLLM / ninfer / llama.cpp / cloud); the column
-- dimension MUST match EMBEDDING_DIM in .env (2560 = qwen3-embedding-4b,
-- the reference model of this stack; edit both together).

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS chunks (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- document identity (SEC accession number, e.g. 0000320193-23-000084)
    doc_id       TEXT   NOT NULL,
    -- filing metadata (from EDGAR, used for retrieval filters)
    company      TEXT   NOT NULL,
    cik          TEXT   NOT NULL,
    ticker       TEXT,
    form         TEXT   NOT NULL,           -- 10-K, 10-Q, 8-K, ...
    filed_at     DATE   NOT NULL,
    -- chunk-level
    section      TEXT,                      -- heading path within the document
    chunk_index  INT    NOT NULL,
    text         TEXT   NOT NULL,
    embedding    vector(2560) NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (doc_id, chunk_index)
);

-- ANN index: cosine similarity. pgvector's HNSW supports at most 2000
-- dimensions; above that (e.g. qwen3-embedding-4b at 2560) create it only
-- when legal, otherwise fall back to sequential scan (fine at this scale).
DO $$
BEGIN
    IF (SELECT atttypmod
          FROM pg_attribute
         WHERE attrelid = 'chunks'::regclass AND attname = 'embedding') <= 2000
    THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS chunks_embedding_hnsw
                   ON chunks USING hnsw (embedding vector_cosine_ops)';
    ELSE
        RAISE NOTICE 'embedding dimension > 2000: skipping HNSW index (pgvector limit)';
    END IF;
END $$;

-- Metadata filters (WHERE cik = ... AND form = '10-K' AND filed_at >= ...)
CREATE INDEX IF NOT EXISTS chunks_doc_idx          ON chunks (doc_id);
CREATE INDEX IF NOT EXISTS chunks_company_form_idx ON chunks (company, form);
CREATE INDEX IF NOT EXISTS chunks_cik_filed_idx    ON chunks (cik, filed_at DESC);
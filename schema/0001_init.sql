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

-- ANN index: cosine similarity over a half-precision EXPRESSION of the
-- embedding, ((embedding)::halfvec(2560)). pgvector's HNSW caps [vector] at
-- 2000 dims but [halfvec] at 4000; the reference stack (2560) falls in
-- between, so the halfvec expression is indexable while the full-precision
-- column is not. The expression index stores no duplicate of the embedding
-- (unlike a generated mirror column), and the search query orders by the same
-- expression so HNSW is used; it then reranks the candidates with the
-- full-precision [embedding] (exact). When the dimension exceeds the halfvec
-- HNSW limit, fall back to a sequential scan. Update BOTH dimensions together
-- with EMBEDDING_DIM.
DO $$
BEGIN
    IF (SELECT atttypmod
          FROM pg_attribute
         WHERE attrelid = 'chunks'::regclass AND attname = 'embedding') <= 4000
    THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS chunks_embedding_hnsw
                   ON chunks USING hnsw ((embedding::halfvec(2560)) halfvec_cosine_ops)';
    ELSE
        RAISE NOTICE 'embedding dimension > 4000: skipping HNSW index (pgvector halfvec limit)';
    END IF;
END $$;

-- Metadata filters (WHERE cik = ... AND form = '10-K' AND filed_at >= ...)
CREATE INDEX IF NOT EXISTS chunks_doc_idx          ON chunks (doc_id);
CREATE INDEX IF NOT EXISTS chunks_company_form_idx ON chunks (company, form);
CREATE INDEX IF NOT EXISTS chunks_cik_filed_idx    ON chunks (cik, filed_at DESC);
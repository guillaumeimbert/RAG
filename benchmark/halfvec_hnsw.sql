-- halfvec_hnsw.sql — benchmark: half-precision HNSW index vs sequential scan
-- at 2560 dims.
--
-- At 2560 dims pgvector's HNSW cannot index the full-precision `vector`
-- column (its HNSW cap is 2000 dims), so an unindexed vector search degrades
-- to a sequential scan that computes a 2560-dim cosine distance for EVERY row
-- and then sorts. The schema's half-precision EXPRESSION index
-- ((embedding::halfvec(2560))) lifts the HNSW cap to 4000 dims, so candidate
-- retrieval becomes an ordered Index Scan. This script measures the difference
-- at the reference 2560-dim width.
--
-- Self-contained: everything runs in a single transaction that is ROLLED BACK
-- at the end, so the script leaves no trace. Run it against the
-- raguesslighter database:
--
--     psql -d raguesslighter -f benchmark/halfvec_hnsw.sql
--
-- Read the steady-state "Time:" lines under each === heading: the indexed (HNSW)
-- query is ~two orders of magnitude faster, and the gap widens as the table
-- grows. The query vector is a 2560-dim constant expression (like the bound
-- parameter in the real Store.search query), which is what lets the planner use
-- the HNSW ordered-scan path. Vectors and rows are synthetic.
\set ON_ERROR_STOP on
\timing off
BEGIN;

CREATE TEMP TABLE bench_chunks (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_id       TEXT   NOT NULL DEFAULT 'd',
    company      TEXT   NOT NULL DEFAULT 'C',
    cik          TEXT   NOT NULL DEFAULT '1',
    ticker       TEXT,
    form         TEXT   NOT NULL DEFAULT '10-K',
    filed_at     DATE   NOT NULL DEFAULT '2026-01-01',
    section      TEXT,
    chunk_index  INT    NOT NULL DEFAULT 0,
    text         TEXT   NOT NULL DEFAULT 'x',
    embedding    vector(2560) NOT NULL
);

-- Setup (not benchmarked): 10,000 distinct 2560-dim vectors.
INSERT INTO bench_chunks (embedding)
SELECT array_to_vector(
         (SELECT array_agg((sin(g::float * 0.001 + h * 0.007) + 1.0) / 2.0)
            FROM generate_series(1, 2560) h),
         2560, false)
FROM generate_series(1, 10000) g;

CREATE INDEX bench_chunks_hnsw
    ON bench_chunks USING hnsw ((embedding::halfvec(2560)) halfvec_cosine_ops);
ANALYZE bench_chunks;

-- A representative 2560-dim cosine nearest-neighbour query (top 5), using a
-- 2560-dim constant query vector (the psql variable :qv substitutes the
-- expression, which the planner treats as a constant).
\set qv array_to_vector(array_fill(0.5, ARRAY[2560]), 2560, false)::halfvec

-- Warm up caches (discarded) so the timed runs are steady-state.
SET enable_seqscan = off;
SELECT count(*) FROM (SELECT id FROM bench_chunks ORDER BY (embedding::halfvec(2560)) <=> (:qv) LIMIT 5) w;
SELECT count(*) FROM (SELECT id FROM bench_chunks ORDER BY (embedding::halfvec(2560)) <=> (:qv) LIMIT 5) w;

\timing on
\echo '=== INDEXED: HNSW Index Scan on (embedding::halfvec(2560)) (enable_seqscan=off) ==='
SET enable_seqscan = off;
SELECT id FROM bench_chunks ORDER BY (embedding::halfvec(2560)) <=> (:qv) LIMIT 5;
SELECT id FROM bench_chunks ORDER BY (embedding::halfvec(2560)) <=> (:qv) LIMIT 5;
SELECT id FROM bench_chunks ORDER BY (embedding::halfvec(2560)) <=> (:qv) LIMIT 5;

\echo '=== UNINDEXED: sequential scan (enable_indexscan=off; no vector HNSW at 2560) ==='
SET enable_seqscan = on;
SET enable_indexscan = off;
SELECT id FROM bench_chunks ORDER BY (embedding::halfvec(2560)) <=> (:qv) LIMIT 5;
SELECT id FROM bench_chunks ORDER BY (embedding::halfvec(2560)) <=> (:qv) LIMIT 5;
SELECT id FROM bench_chunks ORDER BY (embedding::halfvec(2560)) <=> (:qv) LIMIT 5;
\timing off

ROLLBACK;

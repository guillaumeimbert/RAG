# Database schema reference

PostgreSQL 17 with the `vector` extension (pgvector). Schema files in
`schema/` run automatically on first database initialization; apply
them manually on existing databases (see
[How to manage the database](../how-to/database.md)).

## `chunks` — prose retrieval

One row per text chunk of one filing. Written by the ingest pipeline
(HTML → text → chunks → embeddings).

| Column | Type | Notes |
|---|---|---|
| `id` | `BIGINT` identity, PK | |
| `doc_id` | `TEXT NOT NULL` | SEC accession number, e.g. `0000320193-23-000084` |
| `company` | `TEXT NOT NULL` | Filer name as stated in EDGAR |
| `cik` | `TEXT NOT NULL` | 10-digit zero-padded CIK |
| `ticker` | `TEXT NULL` | From `company_tickers.json` when resolvable |
| `form` | `TEXT NOT NULL` | Form code as EDGAR spells it (`10-K`, `SCHEDULE 13G`, …) |
| `filed_at` | `DATE NOT NULL` | Filing date |
| `section` | `TEXT NULL` | Heading path within the document |
| `chunk_index` | `INT NOT NULL` | Position of the chunk within the document |
| `text` | `TEXT NOT NULL` | Chunk text |
| `embedding` | `vector(N) NOT NULL` | `N` = `EMBEDDING_DIM` (2560 in the reference schema); full precision, used for the exact rerank |
| `embedding_hv` | `halfvec(N) GENERATED ALWAYS AS (embedding::halfvec) STORED` | Half-precision mirror of `embedding`, created for the HNSW index (below) |
| `created_at` | `TIMESTAMPTZ` | Default `now()` |

Constraints/indexes: `UNIQUE (doc_id, chunk_index)` (ingest
idempotency); `CHECK (text ~ '[^[:space:]]')` (a chunk must carry at least
one non-whitespace character, added by `0003_chunk_quality.sql` — the
database itself rejects an empty or whitespace-only chunk, not just the
chunker. The POSIX `[^[:space:]]` class covers spaces, tabs, newlines and
the other blanks, which a `btrim` (spaces-only) check would miss. The
migration is corrective: it replaces an earlier space-only constraint and
removes any whitespace-only rows the old one admitted, so it cannot fail on
pre-existing data);
`chunks_embedding_hnsw` on `embedding_hv`
(`halfvec_cosine_ops`) — cosine HNSW over the half-precision mirror. pgvector's
HNSW caps `vector` at 2000 dims but `halfvec` at 4000, so at the reference 2560
dims only the mirror is indexable; the index is created when `N ≤ 4000`
(`0004_halfvec_hnsw.sql` adds the mirror and index to existing databases)
otherwise retrieval falls back to sequential scan. Search retrieves its
candidates through this index (`ORDER BY embedding_hv <=> q`) and then reranks
them with the full-precision `embedding` (ordering the candidates by that exact
similarity), so the half-precision index never degrades result quality;
B-tree indexes on `doc_id`, `(company, form)`, `(cik, filed_at DESC)`
for metadata filters.

A self-contained benchmark (`benchmark/halfvec_hnsw.sql`, rolled back
on exit) measures the two retrieval strategies at the reference 2560
dims: with the HNSW index the nearest-neighbour query is ~0.2 ms, while
a sequential scan over the same 10,000 synthetic vectors takes ~20 ms
(~100×); the gap widens as the store grows.

## `ownership_events` — 13G / 13D

One row per (filer, subject, class) of a beneficial-ownership
statement. Amendments add rows with the same key and a later event
date.

| Column | Type | Notes |
|---|---|---|
| `event_id` | `BIGINT` identity, PK | |
| `accession` | `TEXT NOT NULL` | Filing accession number |
| `form` | `TEXT NOT NULL` | Normalised: `13G`, `13G/A`, `13D`, `13D/A` |
| `event_date` | `DATE NOT NULL` | Date the threshold event occurred |
| `filed_at` | `DATE NOT NULL` | Filing date |
| `filer_cik` | `TEXT NOT NULL` | Reporting person / filer, 10-digit padded |
| `filer_name` | `TEXT NULL` | |
| `subject_cik` | `TEXT NOT NULL` | Issuer whose shares are held, 10-digit padded |
| `subject_name` | `TEXT NULL` | |
| `subject_cusip` | `TEXT NULL` | |
| `class` | `TEXT NOT NULL DEFAULT ''` | Securities class (e.g. `Class A Ordinary Shares`) |
| `shares` | `NUMERIC NULL` | Aggregate beneficially owned; `NULL` when not stated |
| `percent` | `NUMERIC NULL` | Percent of class; `NULL` when not stated |
| `passive` | `BOOLEAN NOT NULL DEFAULT false` | `true` = 13G (passive), `false` = 13D (active) |
| `is_amendment` | `BOOLEAN NOT NULL DEFAULT false` | |
| `index_url` | `TEXT NULL` | EDGAR index page of the filing |
| `created_at` | `TIMESTAMPTZ` | Default `now()` |

Constraints/indexes: `UNIQUE (accession, filer_cik, subject_cik,
class)`; B-tree on `(subject_cik, event_date DESC)` and
`(filer_cik, event_date DESC)`.

## `holdings` — 13F

One row per position in a 13F information table. An amendment re-files
the full table under a new accession.

| Column | Type | Notes |
|---|---|---|
| `accession` | `TEXT NOT NULL` | 13F filing accession number (part of PK) |
| `filer_cik` | `TEXT NOT NULL` | The filer (fund), 10-digit padded |
| `filer_name` | `TEXT NULL` | |
| `period` | `DATE NOT NULL` | `periodOfReport` (quarter end) |
| `filed_at` | `DATE NOT NULL` | |
| `issuer_name` | `TEXT NOT NULL` | As stated in the 13F |
| `issuer_cusip` | `TEXT NOT NULL DEFAULT ''` | Part of PK |
| `issuer_cik` | `TEXT NOT NULL DEFAULT ''` | Resolved by name against the tickers file at ingest; `''` when unresolved |
| `class` | `TEXT NOT NULL DEFAULT ''` | Part of PK |
| `value_usd` | `BIGINT NULL` | Position value in USD |
| `shares` | `NUMERIC NULL` | |
| `prnamt_type` | `TEXT NOT NULL DEFAULT ''` | `SH` / `PRN` / `UNIT`; part of PK |
| `discretion` | `TEXT NULL` | Investment discretion (`SOLE`, `SHARED`, …) |
| `vote_sole` / `vote_shared` / `vote_none` | `NUMERIC NULL` | Voting authority shares |

Indexes: B-tree on `(issuer_cik, period DESC)` and
`(filer_cik, period DESC)`.

## Query conventions

The app's structured queries (`Store.holders_of`,
`Store.positions_of`) select `NUMERIC`/`BIGINT` columns as
`COALESCE(col::float8, -1)`: a value of `-1` in query output means
*not stated*. "Latest per filer" is computed with `ROW_NUMBER()` over
`event_date` (resp. `period`) descending.
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
| `embedding` | `vector(N) NOT NULL` | `N` = `EMBEDDING_DIM` (2560 in the reference schema); full precision. It is stored once and drives both the exact rerank and the HNSW expression index (below) |
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
`chunks_embedding_hnsw` on the EXPRESSION `(embedding::halfvec(N))`
(`halfvec_cosine_ops`) — cosine HNSW over a half-precision cast of the
embedding. It is an expression index, so the half-precision value is computed
on the fly and no duplicate mirror column is stored. pgvector's HNSW caps
`vector` at 2000 dims but `halfvec` at 4000, so at the reference 2560 dims the
full-precision column is not indexable but its half-precision cast is; the
index is created when `N ≤ 4000` (`0004_halfvec_hnsw.sql` converts existing
databases — dropping a pre-existing `embedding_hv` mirror column and any
non-expression index — to the expression index) otherwise retrieval falls back
to sequential scan. Search retrieves its candidates through this index
(`ORDER BY (embedding::halfvec(N)) <=> q`, with the inner `LIMIT` widened to
`candidate_k ≈ min(50, 5·top_k)`), then reranks those candidates with the
full-precision `embedding` (ordering them by that exact similarity) and
truncates to `top_k`: the rerank is exact over the retrieved candidates, so the
result is the true top-k of the candidate set, while the candidate set itself
is approximate (half-precision HNSW) and a metadata-filtered search widens the
scan breadth (`hnsw.iterative_scan=strict_order` plus a large `ef_search`) so a
selective filter does not silently return too few; B-tree indexes on `doc_id`,
`(company, form)`, `(cik, filed_at DESC)` for metadata filters.

A self-contained benchmark (`benchmark/halfvec_hnsw.sql`, rolled back
on exit) measures the two retrieval strategies at the reference 2560
dims: with the HNSW index the nearest-neighbour query is ~0.2 ms, while
a sequential scan over the same 10,000 synthetic vectors takes ~20 ms
(~100×); the gap widens as the store grows.

## `ownership_events` — 13G / 13D

One row per event in a beneficial-ownership statement, keyed by the event's
XML ordinal ([`accession`, `event_index`]). A single 13G/13D filing can
legitimately report the same (filer, subject, class) more than once — the same
stake under different vote types, or multiple class holdings sharing a class
name — each as its own row. Amendments re-file under a new accession.

| Column | Type | Notes |
|---|---|---|
| `event_id` | `BIGINT` identity, PK | |
| `accession` | `TEXT NOT NULL` | Filing accession number |
| `event_index` | `INT NOT NULL` | 0-based ordinal of the event in the filing (UNIQUE with `accession`) |
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

Constraints/indexes: `UNIQUE (accession, event_index)`; B-tree on
`(subject_cik, event_date DESC)` and
`(filer_cik, event_date DESC)`.

## `holdings` — 13F

One row per position in a 13F information table, keyed by the row's XML
ordinal ([`accession`, `position_index`]). A single 13F can legitimately
list the same (cusip, class, SH/PRN) more than once — separate lots, positions
reported for other managers, and put/call splits — each as its own row. 13F
amendments (13F-HR/A) are not ingested (see below), so one accession is always
a single original 13F filing.

| Column | Type | Notes |
|---|---|---|
| `accession` | `TEXT NOT NULL` | 13F filing accession number (part of PK) |
| `position_index` | `INT NOT NULL` | 0-based ordinal of the row in the information table (part of PK) |
| `filer_cik` | `TEXT NOT NULL` | The filer (fund), 10-digit padded |
| `filer_name` | `TEXT NULL` | |
| `period` | `DATE NOT NULL` | `periodOfReport` (quarter end) |
| `filed_at` | `DATE NOT NULL` | |
| `issuer_name` | `TEXT NOT NULL` | As stated in the 13F |
| `issuer_cusip` | `TEXT NOT NULL DEFAULT ''` | |
| `issuer_cik` | `TEXT NOT NULL DEFAULT ''` | Resolved by name against the tickers file at ingest; `''` when unresolved |
| `class` | `TEXT NOT NULL DEFAULT ''` | |
| `value_usd` | `BIGINT NULL` | Position value in USD |
| `shares` | `NUMERIC NULL` | |
| `prnamt_type` | `TEXT NOT NULL DEFAULT ''` | `SH` / `PRN` / `UNIT` (the share-or-principal type, not put/call) |
| `put_call` | `TEXT NOT NULL DEFAULT ''` | SEC `putCall` (`Put` / `Call`); `''` when absent |
| `other_manager` | `TEXT NOT NULL DEFAULT ''` | SEC `otherManager` (Column 7) — a numbered reference to an included other manager; blank / `N/A` / `0` when inapplicable (stored raw) |
| `discretion` | `TEXT NULL` | Investment discretion (`SOLE`, `SHARED`, …) |
| `vote_sole` / `vote_shared` / `vote_none` | `NUMERIC NULL` | Voting authority shares |

Primary key: `(accession, position_index)`. Indexes: B-tree on
`(issuer_cik, period DESC)` and `(filer_cik, period DESC)`. The retrieval
query (`Store.positions_of`) aggregates the rows of each (filer, report) —
summing value and shares across lots — before picking the latest report per
filer.

13F **amendments** (13F-HR/A) are not supported and are skipped at ingest.
The SEC Cover Page distinguishes two kinds (Form 13F FAQ): a *restatement*
resubmits and supersedes the complete original, while an *additive* amendment
supplements it (listing only the positions that changed or were added).
Storing both correctly would mean supersede-on-restatement and merge-on-
additive; that is out of scope, so 13F amendments are never stored. Two
consequences to be aware of:

- The stored report is the **original filing only** — not a guaranteed-complete
  current snapshot once an amendment has been filed. A restatement makes the
  stored original stale; an additive amendment leaves it incomplete.
- The pre-filter (discovery) discards 13F amendments before any index download
  even when they are allow-listed, and the ingest guard skips them before their
  cover / information table. **Rows from amendments ingested before this
  support landed are NOT automatically removed** and, if newer than the
  original, can still win the per-filer `latest_accession` selection — a
  restatement would then drop original positions and an additive amendment
  would show an incomplete holding. If you ever ingested with `FORMS=ALL` or an
  explicit `13F-HR/A`, re-ingest the affected days with `--force` (or reset the
  store) so only original filings are present. The default `FORMS` excludes
  amendments, so this only concerns non-default configurations.

## Query conventions

The app's structured queries (`Store.holders_of`,
`Store.positions_of`) select `NUMERIC`/`BIGINT` columns as
`COALESCE(col::float8, -1)`: a value of `-1` in query output means
*not stated*. "Latest per filer" is computed with `ROW_NUMBER()` over
`event_date` (resp. `period`) descending.
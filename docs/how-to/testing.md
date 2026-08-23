# How to run the test suite

The suite has two parts: **unit tests** (no network, no database) and
the **end-to-end test** (in-process mock servers + a scratch
Postgres database).

## Run everything

```sh
dune build
dune runtest
```

Success looks like:

```
Test Successful in 0.0xx s. 202 tests run.
e2e: PASS
```

If a test fails, dune prints the failing case and writes its full
output to `_build/_tests/...`; re-run a single test executable to see
its output directly:

```sh
./_build/default/test/test.exe          # unit tests only (fast)
dune runtest test/e2e.exe               # the e2e test only
```

## Prerequisites for the e2e test

- Postgres reachable at `127.0.0.1:5432` (start it with
  `podman compose up -d`).
- The e2e test creates and destroys a **scratch** database
  (`raguesslighter_e2e`); your main store is untouched.
- No network: EDGAR and the OpenAI API are served by in-process mock
  HTTP servers (`test/mock.ml`), and every external document is a
  captured fixture in `test/fixtures/`.

### Skip vs. require

When Postgres is not reachable the e2e test **skips** (exit 0) so it
never breaks a local `dune runtest` while the database is down. Set
`RAG_E2E_REQUIRE_PG=1` to turn that into a hard **failure** (exit 1):

```sh
RAG_E2E_REQUIRE_PG=1 ./_build/default/test/e2e.exe
```

CI (`.github/workflows/ci.yml`) provides a `pgvector/pgvector:pg17`
service and sets `RAG_E2E_REQUIRE_PG=1`, so the e2e test can never
silently skip there — a missing database fails the build.

### The CLI exit-code subtest

The e2e test also drives the real `ingest` binary as a subprocess to
check its exit codes (a run with failed filings exits non-zero; a clean
run exits zero). It runs when `RAG_E2E_INGEST_BIN` points at the built
binary, and is skipped otherwise:

```sh
RAG_E2E_INGEST_BIN="$PWD/_build/default/bin/ingest.exe" \
  ./_build/default/test/e2e.exe
```

## What the e2e test covers

- the full ingest pipeline against mock EDGAR + inference servers,
- idempotency (a re-run skips already-ingested filings),
- **failure classification** (fault-injected 429/500 from the inference
  server → `Failed`; a 404 from EDGAR → `Skipped`; a non-404 EDGAR
  error → `Failed`), with nothing stored for a failed filing,
- **transaction semantics** (a write followed by a failure in the same
  transaction rolls back; `upsert_13gd` is atomic across its events and
  chunks),
- **forced re-ingest** (`--force` replaces stored rows without
  duplicating them),
- **retrieval relevance** (hand-crafted orthogonal unit vectors, so the
  test checks the store ranks by *actual* cosine similarity — a revenue
  query ranks the revenue chunk first, an unrelated query is dissimilar
  to everything),
- **similarity threshold** (`MIN_SIMILARITY`): an unrelated query above
  the floor returns **no** results (the path `ask` takes to avoid feeding
  the LLM irrelevant material), while a relevant query still passes,
- **half-precision vector index**: the `chunks` table stores the full-precision
  `embedding` once and indexes its half-precision EXPRESSION
  `embedding::halfvec(N)` (no duplicate mirror column; pgvector caps `vector`
  HNSW at 2000 dims but `halfvec` at 4000, so the reference 2560 is
  indexable); the test confirms there is no generated mirror column, that the
  HNSW index is the halfvec expression, that candidate retrieval is an Index
  Scan, and that `0004_halfvec_hnsw.sql` converts an old-style database
  (generated mirror column) to the expression index,
- **structured retrieval** (latest-event-per-filer selection,
  previous-event deltas, multiple filers, amendment flag),
- **chunk quality / data integrity** (every stored chunk is nonempty,
  within `CHUNK_SIZE`, and free of section markers and leaked HTML tags;
  the database itself rejects a whitespace-only chunk via its `CHECK`
  constraint and never stores it),
- **schema migration upgrade** (a database that was created with the old
  space-only `btrim` constraint — and so may hold tab/newline-only junk
  chunks the old check admitted — is upgraded by `0003_chunk_quality.sql`
  without failing: the migration removes the junk rows and installs the
  stronger regex `CHECK`; a fresh tab/newline-only insert is then rejected),
- **master-index discovery pre-filter** (`ingest day`): the day's master
  index is fetched once and the `FORMS` allow-list is applied to it before
  any per-filing fetch, so the index pages of allow-listed filings are
  fetched while the index pages of non-allow-listed filings (a Form 4 and a
  424B2 in the mock) are provably **never requested**),
- **ownership ingestion through the master path** (`ingest day`): a
  `SCHEDULE 13G` and a `13F-HR` in the day's master index are both
  ingested — the 13G's event is stored (the index parser captures the full
  spaced form name and fetches the data `.xml`, not the `.html` twin) and
  the 13F's positions are stored (the information table is resolved from
  the index-named `infotable.xml`, not an assumed file name), while a
  non-allow-listed Form 4 in the same master file is pre-filtered out),
- **malformed 13F information table**: a 13F whose information table
  downloads fine but is well-formed XML with no `infoTable` rows (truncated
  or schema-invalid) is classified as `Failed`, not `Skipped` — a table that
  parses to zero positions is not treated as an empty holdings list (a
  genuine 13F discloses at least one holding),
- **CLI exit codes** (via the built binary, when `RAG_E2E_INGEST_BIN`
  is set).

## Notes

- The unit tests also cover the **ask citation mapping** (`Grounding`):
  the *i*-th hit must carry citation `[i+1]` in both the excerpts block
  given to the LLM and the Sources block printed after its answer, so the
  model's `[n]` markers resolve to the right filing.
- The e2e test applies the schema files itself, in order (`0001` through
  `0004_halfvec_hnsw.sql`). If you add `schema/0005_*.sql`, add it to
  `test/e2e.ml`'s apply list too.
- Fault injection makes 429/5xx retry loops finish instantly
  (`Net.set_backoff_scale 0.0` in the test), so a run that would
  otherwise retry for ~15 s per request completes in milliseconds.
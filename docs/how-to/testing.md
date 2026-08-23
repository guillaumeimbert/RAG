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
- **CLI exit codes** (via the built binary, when `RAG_E2E_INGEST_BIN`
  is set).

## Notes

- The e2e test applies the schema files itself, in order — if you add
  `schema/0003_*.sql`, add it to `test/e2e.ml`'s apply list too.
- Fault injection makes 429/5xx retry loops finish instantly
  (`Net.set_backoff_scale 0.0` in the test), so a run that would
  otherwise retry for ~15 s per request completes in milliseconds.
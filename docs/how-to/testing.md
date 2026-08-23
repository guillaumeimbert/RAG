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

- Postgres reachable at `DATABASE_URL` (start it with
  `podman compose up -d`).
- The e2e test creates and destroys a **scratch** database
  (`raguesslighter_e2e`); your main store is untouched.
- No network: EDGAR and the OpenAI API are served by in-process mock
  HTTP servers (`test/mock.ml`), and every external document is a
  captured fixture in `test/fixtures/`.

## Notes

- The e2e test applies the schema files itself, in order — if you add
  `schema/0003_*.sql`, add it to `test/e2e.ml`'s apply list too.
- A scratch developer tool (not a test) is
  `test/scratch_ownership_probe.ml`: it fetches and parses live SEC
  XML. Run it with
  `dune exec test/scratch_ownership_probe.exe` — it needs network
  access to the SEC and a configured `SEC_USER_AGENT`.
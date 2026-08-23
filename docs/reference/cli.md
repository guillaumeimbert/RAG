# CLI reference

Three executables, built by `dune build`:

- `dune exec bin/ingest.exe` — ingest SEC filings into the store.
- `dune exec bin/query.exe` — search and query the store.
- `dune exec bin/migrate.exe` — apply the schema migrations.

Both accept `-e FILE, --env-file=FILE` (default `.env`) on every
subcommand, and `--help[=FMT]` (`FMT` = `auto`, `pager`, `groff`,
`plain`). Exit status: `0` success, `123` error reported on stderr,
`124` command-line parsing error, `125` internal error.

## ingest.exe

### `ingest day DATE`

Ingest all matching filings for one business day (`DATE` =
`YYYY-MM-DD`). Weekend/holiday dates have no data and report zero
documents.

Options: `-e FILE`, `-F, --force`.

### `ingest backfill --from DATE --to DATE`

Ingest a range of business days, inclusive. Weekends are skipped
directly; US market holidays have no daily-index master file and therefore
no data. A `total` summary line is printed at the end.

Options: `-e FILE`, `--from=DATE` (required), `--to=DATE` (required), `-F, --force`.

### `ingest ticker TICKER`

Ingest the recent filings of one company, resolved from
`company_tickers.json` (or `SEC_COMPANY_TICKERS_URL`). Errors with
`unknown ticker` when the ticker is not in the file.

Options: `-e FILE`, `-l N, --limit=N` (default `0` = all recent
filings), `-F, --force`.

### `ingest cik CIK`

Same as `ticker`, by CIK (10-digit or unpadded).

Options: `-e FILE`, `-l N, --limit=N`, `-F, --force`.

### `ingest stats`

Print the store contents:

```
documents:        <n>
chunks:           <n>
ownership events: <n>
13F positions:    <n>
```

Options: `-e FILE`.

### `--force` / `-F`

Bypass the "already ingested" check and replace the stored rows for
each filing (an atomic delete-then-write per accession). Use it to
repair or rebuild filings that are already in the store — for example
after a parser or embedding-model change. Applies to `day`,
`backfill`, `ticker`, and `cik`. A run with a non-zero `failed` count
exits `123` (error), so a failed ingest is never reported as success.

## query.exe

### `query search TEXT`

Vector search over the `chunks` table. Prints up to `k` hits: rank,
cosine similarity, `COMPANY (TICKER) — FORM, filed DATE, "section"`,
and a truncated snippet. Prints `no results` when nothing matches.

Options:

- `-k N, --top-k=N` (default `TOP_K` from `.env`)
- `--ticker=TICKER`, `--cik=CIK`, `--form=FORM` — metadata filters
  (one each; combined with `AND`)
- `-e FILE`

### `query ask TEXT`

Grounded question answering: retrieves the top passages (same
filters as `search`), sends them to the chat model with a grounded
prompt, and prints the answer plus the numbered sources. When the
question matches the ownership screen (keywords: holders, ownership,
stake/stakes/staked, institutional, portfolio, 13f/13d/13g,
"who owns/holds", percent) and its words resolve to at most 2
companies, the exact `ownership_events`/`holdings` rows for those
companies are appended as a structured evidence block, and the
sources list ends with a `[SQL]` marker. Prints `no results` when
both prose hits and structured evidence are empty.

Options: same as `search`.

### `query holders --subject TICKER|CIK`

Structured ownership query, pure SQL, no inference server. `--subject`
is a ticker, a company name, or a CIK (10-digit or unpadded). Prints
two sections, each capped at `limit` rows:

- **13G/13D significant holders** — latest `ownership_events` row per
  filer for the subject, with the previous event's percent/shares in
  parentheses when an earlier event exists.
- **13F institutional positions** — latest `holdings` report per
  filer for the subject.

Figures not stated in the filing print as `not stated`.
Resolution failures print `could not resolve <subject> to a CIK`.

Options: `-l N, --limit=N` (default `10`), `-s TICKER|CIK,
--subject=TICKER|CIK` (required), `-e FILE`.

## migrate.exe

Apply the numbered `schema/*.sql` migrations. Migrations are a deployment
step (they are not run automatically by `Store.create`). Every command takes
`-e FILE, --env-file=FILE` (default `.env`) and `--help[=FMT]`. The tool only
reads `DATABASE_URL` from the `.env` file — it does not require the inference,
SEC, or chunking configuration.

The applied history must be a **valid prefix** of the available files: every
recorded version is a local file, and the recorded set is exactly the first
`k` local versions (no gaps, no unknown versions, no missing files). A history
that is not a valid prefix (e.g. `0001` and `0003` recorded but not `0002`)
is an error on `up` and `status`.

### `migrate up`

Apply the missing migrations, in ascending file order. Each migration runs in
its own transaction (its SQL statements and its `schema_migrations` record
commit or roll back together), under a PostgreSQL advisory lock so concurrent
`up` runs are serialized. Already-applied migrations are skipped. On an empty
database this brings the schema up to date; on an existing database it applies
only the new files.

A database created before the `schema_migrations` tracker existed (the schema
present but with no records) is brought up to date by `up`: the migrations are
idempotent and corrective (they guard each structural change), so re-running
them converges the schema to the current definitions before the checksums are
recorded. There is no separate "record without re-running" command — re-running
is safe and guarantees the converged definitions match the recorded checksums.

The applied migrations' checksums are verified against their files (an
immutability guard): a recorded migration whose file has changed is an error.
Never edit an applied migration — add a new `NNNN_*.sql` file instead.

### `migrate status`

Report the applied and pending migrations (no changes). The `schema_migrations`
table is created (and the advisory lock is taken) so the command is safe on an
empty database. Refuses an inconsistent applied history.
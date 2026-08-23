# CLI reference

Two executables, built by `dune build`:

- `dune exec bin/ingest.exe` — ingest SEC filings into the store.
- `dune exec bin/query.exe` — search and query the store.

Both accept `-e FILE, --env-file=FILE` (default `.env`) on every
subcommand, and `--help[=FMT]` (`FMT` = `auto`, `pager`, `groff`,
`plain`). Exit status: `0` success, `123` error reported on stderr,
`124` command-line parsing error, `125` internal error.

## ingest.exe

### `ingest day DATE`

Ingest all matching filings for one business day (`DATE` =
`YYYY-MM-DD`). Weekend/holiday dates have no data and report zero
documents.

Options: `-e FILE`.

### `ingest backfill --from DATE --to DATE`

Ingest a range of business days, inclusive. Weekends are skipped
directly; US market holidays have no sitemap and therefore no data. A `total` summary line is printed at the end.

Options: `-e FILE`, `--from=DATE` (required), `--to=DATE` (required).

### `ingest ticker TICKER`

Ingest the recent filings of one company, resolved from
`company_tickers.json` (or `SEC_COMPANY_TICKERS_URL`). Errors with
`unknown ticker` when the ticker is not in the file.

Options: `-e FILE`, `-l N, --limit=N` (default `0` = all recent
filings).

### `ingest cik CIK`

Same as `ticker`, by CIK (10-digit or unpadded).

Options: `-e FILE`, `-l N, --limit=N`.

### `ingest stats`

Print the store contents:

```
documents:        <n>
chunks:           <n>
ownership events: <n>
13F positions:    <n>
```

Options: `-e FILE`.

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
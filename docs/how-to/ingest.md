# How to ingest filings

All ingest commands are `dune exec bin/ingest.exe -- <command>` below
(abbreviated `ingest.exe` here). They read `.env`; use `--env-file`
to point at another file.

## Ingest one company

By ticker (resolves the CIK via `company_tickers.json`):

```sh
ingest.exe ticker NVDA
```

By CIK (10-digit or unpadded):

```sh
ingest.exe cik 0001045810
```

To ingest only the most recent N filings instead of the company's
whole recent history:

```sh
ingest.exe ticker NVDA --limit 20
```

The command prints a summary line (`docs=… chunks=… events=…
positions=… skipped=… failed=…`). `skipped` counts filings already in
the store — re-running the same command is safe and changes nothing.
`failed` counts filings whose embedding or database write failed; the
run exits non-zero when it is non-zero (nothing partial was stored —
writes are transactional — so a re-run retries those filings).

## Ingest one business day

```sh
ingest.exe day 2026-08-20
```

This fetches the **complete** filing set for that date (roughly 5,000
accessions) and ingests the ones matching `FORMS`. It prints one line
per day. If the date is a weekend or US market holiday there is
nothing to fetch and the command reports no documents.

## Backfill a range of days

```sh
ingest.exe backfill --from 2026-08-01 --to 2026-08-20
```

Weekends are skipped directly; US market holidays are skipped because
they have no sitemap. A `total` line with the aggregate stats prints
at the end.

## Ingest more or fewer forms

Edit `FORMS` in `.env` (comma-separated form codes, case as EDGAR
spells them):

```
FORMS=10-K,10-K/A,10-Q,10-Q/A,8-K,8-K/A,20-F,20-F/A,6-K,13G,13D,13F-HR
```

- The default set (above) covers core periodic/event disclosures plus
  the ownership schedules.
- `FORMS=ALL` includes everything — registration statements, proxy
  statements, Forms 3/4/5 — roughly 5,000 filings/day instead of a few
  hundred.
- Form matching is by normalised code: `FORMS=13G` also matches
  EDGAR's "SCHEDULE 13G" spelling, and `13G/A` is distinct from
  `13G`.

Changes apply to **new** ingests only; already-stored filings are not
reclassified.

## Verify what is in the store

```sh
ingest.exe stats
```

```
documents:        90
chunks:           4767
ownership events: 3
13F positions:    63
```

`documents`/`chunks` count the prose path; `ownership events` and
`13F positions` count the structured tables.

## Troubleshooting

- `connection refused` → the database is down: `podman compose up -d`.
- `unknown ticker: XYZ` → the ticker is not in
  `company_tickers.json`; use `cik <CIK>` instead (find the CIK on
  EDGAR's browse page).
- `403` from the SEC → `SEC_USER_AGENT` must contain your name and a
  contact address.
- A filing line like `skip 000…: parse error …` → one filing's
  document was unparseable; it is skipped and the run continues.
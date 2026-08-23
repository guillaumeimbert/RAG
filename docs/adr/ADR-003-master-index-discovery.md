# ADR-003 — Ingest discovery: daily-index master file instead of sitemaps

**Status:** accepted (2026-08-22)

Supersedes the discovery mechanism (decision 1) of
[ADR-001](ADR-001-ingest-discovery.md). The per-CIK `submissions` JSON source
for targeted `--cik`/`--ticker` ingest is unchanged.

## Context

ADR-001 chose the daily-index **sitemap**
(`Archives/edgar/daily-index/{YYYY}/QTR{q}/sitemap.{YYYYMMDD}.xml`) as the
discovery source for "every filing of a business day". The sitemap lists one
`<loc>` per filing pointing at the filing's **index page**
(`…/data/{cik}/{acc}-index.htm`). The pipeline then fetched **every** index
page to read the form type and `primaryDocument`, and only then applied the
`FORMS` allow-list.

Two problems:

1. **Cost.** A business day's sitemap lists ~3,000 accessions, so the pipeline
   fetched ~3,000 index pages per day just to discover the ~380 that matched
   `FORMS`. ~87% of those index fetches were wasted.
2. **The index page is fetched twice conceptually.** The sitemap already gives
   the accession; the index page is fetched only to learn the form and the
   primary document. If the form is not allow-listed, the fetch was wasted.

The daily-index directory also publishes a **master** file
(`master.{YYYYMMDD}.idx`) that ADR-001 had not considered. It is a single
pipe-delimited table with one row per (CIK, filing) event:

```
CIK|Company Name|Form Type|Date Filed|File Name
1045810|NVIDIA CORP|10-K|20260820|edgar/data/1045810/0001045810-26-000021.txt
```

It carries the **form type** and the **CIK** directly, so the allow-list
filter can be applied **before** any per-filing fetch.

## Evidence (verified live 2026-08-22)

For `master.20260820.idx` vs `sitemap.20260820.xml`:

| Metric | Master | Sitemap |
|---|---|---|
| raw rows / `<loc>` entries | 4,183 | 4,183 |
| distinct accessions | **3,041** | **3,041** |
| accessions only in one | 0 | 0 |
| duplicate accession rows (same acc, several CIKs) | 1,142 | 1,142 |
| form type per filing | **yes** | no |

- The master and the sitemap cover the **same** set of accessions for a
  business day (0 asymmetric). The master is therefore a complete discovery
  source, not a sample.
- Because it carries the form type, the default `FORMS` allow-list shrinks
  the 3,041 accessions to **382** *before* any index page is fetched. The
  sitemap cannot do this: with no form type it must fetch all 3,041 index
  pages to learn each filing's form.
- The master lists the same accession once per related CIK (1,142 duplicate
  rows on 2026-08-20, as does the sitemap); **deduping by accession** (first
  occurrence wins) is required and loses nothing.
- CIKs in the master matched the CIK in the sitemap's file path for every row
  (0 mismatches), so the master's CIK column is a reliable basis for the
  index-page URL.
- The master's `Form Type` uses the same vocabulary as the index pages
  (`10-K`, `10-K/A`, `8-K`, `SCHEDULE 13G`, `SC 13D`, …), so it feeds the
  existing `Ownership.norm_form` + `Config.forms_allow` filter unchanged.

## Decision

1. **Discovery** = the daily-index **master** file
   (`Archives/edgar/daily-index/{YYYY}/QTR{q}/master.{YYYYMMDD}.idx`),
   parsed with a hand-rolled line/pipe parser (`Edgar.parse_master`), robust
   to header and separator placement (a data row is identified structurally:
   five pipe-separated fields, numeric CIK, `YYYYMMDD` date, and a file name
   containing `/`).
2. **Pre-filter** = apply `FORMS` to the master's `Form Type`
   **before** fetching any index page. Rows that do not match are dropped;
   only allow-listed accessions have their index page fetched (to read
   `primaryDocument` and any per-filing metadata the master lacks).
3. **Dedupe** = by accession (first occurrence wins), because the master lists
   the same accession under each related CIK.
4. **Safety net** = after fetching an allow-listed filing's index page, the
   pipeline re-checks the index page's own form against `FORMS` (the master's
   `Form Type` and the index page can in principle disagree, e.g. for
   amendments). A disagreement drops the filing.
5. **No sitemap fallback.** The sitemap and the master are published together
   per business day; a 404 on the master means a holiday/non-business day
   (exactly as a 404 on the sitemap did). `master_of_day` raises `Failure` on
   a missing master or an empty parse, matching the previous `filings_of_day`
   semantics.

## Consequences

- Per business day: **1** master fetch + index-page fetches for allow-listed
  filings only (~382 with the default `FORMS`, down from ~3,000) — an ~87%
  reduction in SEC index-page traffic.
- The `Gz` module remains in use (the submissions and company-tickers JSONs
  are gzip-decoded transparently by `Net`); only the sitemap code
  (`parse_sitemap`, `filings_of_day`, the sitemap fixtures) was removed.
- The master's format is pinned by `test/fixtures/master.idx` and
  `test/test_edgar.ml`; the e2e proves the pre-filter never fetches the index
  page of a non-allow-listed filing.
- If the master file ever disappears or changes shape, the sitemap (ADR-001's
  original source) is a complete, equivalent fallback that can be re-added;
  the rest of the pipeline (index page → primary document) is unaffected.
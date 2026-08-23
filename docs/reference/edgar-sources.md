# EDGAR source reference

The SEC publishes filings through several public endpoints. No API
key is required; a static `User-Agent` with contact info is required
(fair access policy, ≤ 10 requests/second). All URLs below use the
default base URLs from
[configuration](configuration.md#sec-edgar).

## Endpoints used by RAGuessLighter

### Daily-index master file — complete per-business-day filing list

```
{SEC_DAILY_INDEX_BASE}/{YYYY}/QTR{q}/master.{YYYYMMDD}.idx
```

- A single pipe-delimited table, one row per (CIK, filing) event:
  `CIK|Company Name|Form Type|Date Filed|File Name`, e.g.
  `1045810|NVIDIA CORP|10-K|20260820|edgar/data/1045810/0001045810-26-000021.txt`.
- **Complete** for the business day: the master and the (older) sitemap
  cover the same accessions; the master lists ~3,000 distinct accessions in
  2026-08, with the same accession repeated once per related CIK.
- Carries the **form type** and the **CIK** directly, so the `FORMS`
  allow-list is applied *before* any per-filing fetch — only allow-listed
  accessions have their index page fetched. (An ~87% reduction in index-page
  traffic versus fetching every filing's index page.)
- `QTR{q}` is the **calendar** quarter (QTR1 = Jan–Mar, …, QTR4 = Oct–Dec);
  the date-first URL form returns 403.
- Parsed with a structural row detector (five pipe-separated fields, numeric
  CIK, `YYYYMMDD` date, file name containing `/`), so header/separator
  placement is irrelevant. Deduped by accession (first occurrence wins).
- Used by: `ingest day`, `ingest backfill`.

> ADR-001 originally chose the daily-index **sitemap**
> (`sitemap.{YYYYMMDD}.xml`) for discovery; ADR-003 supersedes that with the
> master file, which carries the form type and lets the pipeline pre-filter
> before fetching index pages.

### Per-CIK submissions JSON — company filing history

```
{SEC_SUBMISSIONS_BASE}/CIK{cik-10-digit}.json
```

- Full filing history: a `recent` object plus `files[]` archives back
  to 1994.
- Each entry: `accessionNumber`, `form`, `filingDate`,
  `primaryDocument`, `primaryDocumentDescription`, `items`.
- Used by: `ingest ticker`, `ingest cik`, and ticker→CIK
  resolution is separate (`company_tickers.json`).

### Filing index page — document listing

```
{SEC_ARCHIVES_BASE}/{cik-unpadded}/{accession-dashed}-index.htm
```

- HTML page; lists the documents of the filing, with the
  `primaryDocument` identified by an id.
- Some filings (letter/anonymous) carry no form metadata and no
  documents; the parser returns nothing for those and the pipeline
  skips the filing.
- Used by: the ingest pipeline (one request per filing).

### Static documents — the filing content

```
{SEC_ARCHIVES_BASE}/{cik-unpadded}/{accession-dashed}/{document}
```

- Plain, static, cacheable. Two document families matter:
  - **Primary document**: the filing body. For narrative forms (10-K,
    8-K, …) the index lists a single primary document, which the app
    fetches. For ownership filings (13F/13G/13D) the index lists the data
    `.xml` right beside a `.html` "friendly" twin under the **same Type**;
    the app selects the `.xml` row (the raw data at the accession root) and
    fetches that, not the `.html` (whose link is styled `xsl…/` output).
  - **13F information table**: the 13F-HR holdings table, listed on the
    index as the `INFORMATION TABLE` document. Its file name varies by
    filer (e.g. `infotable.xml`), so the app reads the name from the index
    rather than assuming one.
- Used by: the ingest pipeline (prose path) and the ownership
  parsers (structured path).

### Ticker → CIK file

```
https://www.sec.gov/files/company_tickers.json
```

- Flat JSON object, ~25,000 entries: `{"ticker": {"cik_str": 320193,
  "title": "Apple Inc.", ...}, …}`.
- Cached in-process for the life of the command.
- Used by: `ingest ticker`, `query holders --subject`, the `ask`
  ownership screen, and 13F issuer resolution.

## Endpoints available but not used by v1

| Endpoint | Purpose | Note |
|---|---|---|
| `{SEC_BROWSE_EDGAR_BASE}?action=getcurrent&output=atom` | "Current filings" Atom feed | **Sample only** (capped at 100 entries); not complete for a day |
| `{SEC_FTS_BASE}` | EDGAR full-text search API | Date/form/text filters; candidate for future backfill tooling |
| `{SEC_DAILY_INDEX_BASE}/bulkdata/submissions.zip` | Whole-universe submissions archive | ~1.56 GB, republished nightly ~03:00 ET; fallback for full backfill |

## Identifiers

- **Accession number**: `CIK-cy-seq` (e.g. `0000320193-23-000084`),
  10-digit CIK, 2-digit year, 6-digit sequence. The index-page URL
  uses the **dashed** form (`…/{cik}/0000320193-23-000084-index.htm`);
  the document directory uses the **undashed** form
  (`…/{cik}/000032019323000084/…`). The store keeps the dashed form as
  `doc_id` / `accession`.
- **CIK**: 10-digit zero-padded in the store; unpadded in URL paths.
- **Form codes**: EDGAR spells some forms with a schedule prefix
  (`SCHEDULE 13G`); the app normalises to `13G` for matching and
  storage (`Ownership.norm_form`).

See [ADR-001](../adr/ADR-001-ingest-discovery.md) for the original
discovery-source analysis, [ADR-002](../adr/ADR-002-heterogeneous-retrieval.md)
for the ownership-source decisions, and
[ADR-003](../adr/ADR-003-master-index-discovery.md) for the switch to the
daily-index master file for discovery.
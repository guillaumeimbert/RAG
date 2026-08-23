# EDGAR source reference

The SEC publishes filings through several public endpoints. No API
key is required; a static `User-Agent` with contact info is required
(fair access policy, ≤ 10 requests/second). All URLs below use the
default base URLs from
[configuration](configuration.md#sec-edgar).

## Endpoints used by RAGuessLighter

### Daily-index sitemaps — complete per-business-day filing lists

```
{SEC_DAILY_INDEX_BASE}/{YYYY}/QTR{q}/sitemap.{YYYYMMDD}.xml
```

- One `<loc>` entry per filing: the short index-page URL
  `http://www.sec.gov/Archives/edgar/data/{cik}/{accession-dashed}-index.htm`.
- **Complete** for the business day (~5,000 accessions in 2026-08).
- `QTR{q}` is the **calendar** quarter (QTR1 = Jan–Mar, …, QTR4 =
  Oct–Dec); the date-first URL form returns 403.
- Served gzip only when `Accept-Encoding: gzip` is sent (~30×
  smaller); the app requests gzip and decodes by magic bytes.
- The same accession may appear under several CIK directories
  (letter/anonymous filings); the app dedupes by accession.
- Used by: `ingest day`, `ingest backfill`.

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
  - **Primary document** (HTML): the human-readable filing, 1 KB to
    ~20 MB. For narrative forms the app fetches the document listed
    as `primaryDocument` on the index page; for ownership filings the
    listed primary document is styled HTML, so the app instead fetches
    the **raw XML at the accession root**.
  - **Raw XML at the accession root**: `primary_doc.xml` (the 13G/13D
    cover, or the 13F cover) and, for 13F-HR, `information_table.xml`
    (the holdings table). The `xsl…/primary_doc.xml` variant listed on
    the index page is styled HTML, not data, and is not used.
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

See [ADR-001](../adr/ADR-001-ingest-discovery.md) for the
discovery-source analysis and [ADR-002](../adr/ADR-002-heterogeneous-retrieval.md)
for the ownership-source decisions.
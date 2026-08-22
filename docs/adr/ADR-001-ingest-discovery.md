# ADR-001 — Ingest discovery: daily-index sitemaps + submissions JSON

**Status:** accepted (2026-08-22)

## Context

We need a complete, fair-access-compliant source for "every EDGAR filing of a
given day" (the `browse-edgar?action=getcurrent` firehose), plus per-company
history for targeted ingest. Candidate sources, verified live 2026-08-22:

| Source | Completeness | Cost | Verdict |
|---|---|---|---|
| `browse-edgar?output=atom` | **Capped at 100 entries** (yesterday had 4,983 filings) | trivial | sample only |
| `Archives/edgar/daily-index/YYYY/QTRn/sitemap.YYYYMMDD.xml` | **complete** per business day (one accession per filing, CIK derivable) | 1 request/day | **adopt** |
| `Archives/edgar/daily-index/bulkdata/submissions.zip` | complete per-CIK universe | 1.56 GB/night (republished ~03:00 ET) | fallback / whole-universe backfill |
| `data.sec.gov/submissions/CIK##########.json` | per-CIK history (recent + `files[]` arrays to 1994) | 1 request/CIK | **adopt** for `--cik`/`--ticker` |
| `efts.sec.gov/LATEST/search-index` | full-text search | 1 request/query | optional backfill filter |

Notes:
- Daily-index files use **calendar quarters** (QTR1 = Jan–Mar … QTR4 =
  Oct–Dec); URL layout is `Archives/edgar/daily-index/{YYYY}/QTR{q}/
  sitemap.{YYYYMMDD}.xml` (verified live 2026-08-22; the date-first form
  returns 403). Served as `text/xml` identity by default, gzip only when
  `Accept-Encoding: gzip` is requested (~30x: 1.08 MB → 35 KB). The client
  requests gzip and decodes by magic bytes, so both encodings are handled and
  pinned by fixtures (plain + gzip captures of the same content).
- The `<loc>` entries use the short index-page form
  `http://www.sec.gov/Archives/edgar/data/{cik}/{acc-dashed}-index.htm`
  (unpadded CIK, `http://` — upgraded to `https`; verified live), not the
  long form with an undashed-accession directory.
- One sitemap lists the same accession under several CIK directories (e.g.
  CIK-0 anonymous/letter filings appear under each related filer's CIK); the
  2026-08-21 sitemap had 4,983 `<loc>` lines = 3,719 distinct accessions.
  Deduping by accession is therefore correct and loses nothing.
- Some index pages (letter/anonymous filings) have **no form metadata at
  all** — no form section, no filing date, no HTML documents. `parse_index`
  returns `None` for those and the pipeline skips the filing (verified live;
  format pinned by `test/fixtures/letter_filing_index.html`). A day's ingest
  must not die on one such filing.
- The SEC's official API page
  (`/search-filings/edgar-application-programming-interfaces`) documents
  submissions + XBRL + bulk ZIPs but not the daily sitemaps (undocumented but
  stable since at least 2026 QTR1; we will pin the format in tests).
- Fair access: static `User-Agent` with contact info, ≤ 10 req/s, no API key.

## Decision

1. **Discovery** = daily-index sitemaps (backfill and daily increment);
   per-CIK `submissions` JSON for targeted ingest.
2. **Documents** = filing index page → `primaryDocument` URL on
   `Archives/edgar/data/` (static, cacheable).
3. **Dedupe** = upsert keyed on `(accession_number, chunk_index)`; re-runs are
   idempotent.
4. **Scope** = `FORMS` allow-list (default 10-K/10-Q/8-K/20-F/6-K + amendments),
   overridable to `ALL`.
5. **XBRL** `companyfacts`/`frames` are out of scope for v1 (structured numeric
   queries = future ADR); the text pipeline embeds the human-readable documents.

## Consequences

- ~5,000 index-page fetches per business day at 10 req/s ≈ 10 min of SEC
  traffic per day; primary docs only for allow-listed forms.
- A 90-business-day backfill is ~90 sitemap requests + per-filing index fetches.
- If the daily-index format ever changes, the bulk `submissions.zip` is the
  documented fallback discovery source.
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
- Daily-index files use **calendar quarters** (QTR1 = Jan–Mar … QTR4 = Oct–Dec);
  each `sitemap.YYYYMMDD.xml` is gzip-compressed despite the `.xml` extension
  (content is XML).
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
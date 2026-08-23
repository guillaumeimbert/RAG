# Configuration reference

All settings live in a `.env` file (gitignored; the template is
`.env.example`). The file is re-read on every command; there is no
daemon and no restart. `--env-file FILE` (or `-e`) selects a
different file on a per-invocation basis.

## Database

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `postgresql://raguesslighter:raguesslighter@localhost:5432/raguesslighter` | Postgres connection string. Must match `compose.yaml` (user, password, database, port). |

## Inference (OpenAI-compatible)

| Variable | Default | Description |
|---|---|---|
| `OPENAI_BASE_URL` | `http://localhost:8000/v1` | Base URL of the chat server. Must end in `/v1`. |
| `OPENAI_API_KEY` | `not-needed` | Bearer key for the chat server. Any non-empty string works with local servers. |
| `LLM_MODEL` | `qwen2.5:14b` | Model name for `chat/completions`. |
| `OPENAI_EMBED_BASE_URL` | *(unset)* | Base URL of a separate embeddings server. When unset, `OPENAI_BASE_URL` is used. |
| `OPENAI_EMBED_API_KEY` | *(unset)* | Key for the embeddings server. When unset, `OPENAI_API_KEY` is used. |
| `EMBEDDING_MODEL` | `nomic-embed-text` | Model name for `embeddings`. |
| `EMBEDDING_DIM` | `2560` | Output dimension. **Must equal** the `vector(N)` column in `schema/0001_init.sql`. HNSW index is created only when N ≤ 2000. |

## SEC EDGAR

| Variable | Default | Description |
|---|---|---|
| `SEC_USER_AGENT` | `Your Name <you@example.com>` | Sent as the `User-Agent` on every SEC request. The SEC requires a real contact; anonymous clients get HTTP 403. See [About SEC fair access](../explanation/about-sec-fair-access.md). |
| `SEC_BROWSE_EDGAR_BASE` | `https://www.sec.gov/cgi-bin/browse-edgar` | Browse-EDGAR endpoint (current-filings sample). |
| `SEC_DAILY_INDEX_BASE` | `https://www.sec.gov/Archives/edgar/daily-index` | Daily-index sitemaps (complete per-business-day filing lists). |
| `SEC_SUBMISSIONS_BASE` | `https://data.sec.gov/submissions` | Per-CIK submission history JSON. |
| `SEC_FTS_BASE` | `https://efts.sec.gov/LATEST/search-index` | EDGAR full-text search API (unused by v1 commands; available for backfill tooling). |
| `SEC_ARCHIVES_BASE` | `https://www.sec.gov/Archives/edgar/data` | Static document store (filing HTML and raw XML). |
| `SEC_COMPANY_TICKERS_URL` | `https://www.sec.gov/files/company_tickers.json` | Ticker→CIK file. Flat JSON object; each entry has `ticker`, `cik_str` (int), `title`. |
| `FORMS` | `10-K,10-K/A,10-Q,10-Q/A,8-K,8-K/A,20-F,20-F/A,6-K,13G,13D,13F-HR` | Comma-separated allow-list of form codes to ingest. Matching is by normalised code (`FORMS=13G` matches EDGAR's `SCHEDULE 13G`). `ALL` ingests every form. |

## Chunking and retrieval

| Variable | Default | Description |
|---|---|---|
| `CHUNK_SIZE` | `1200` | Target chunk length in characters. |
| `CHUNK_OVERLAP` | `200` | Overlap between consecutive chunks, in characters. |
| `TOP_K` | `8` | Default number of hits for `query search` / `ask` (overridden by `-k`). |
| `MIN_SIMILARITY` | `0.0` | Cosine-similarity floor for vector search. Hits below it are dropped, so an unrelated query can return **no** results instead of the nearest `TOP_K` (which `ask` would otherwise feed to the LLM as evidence). `0.0` disables the filter. Tune against your embedding model's score distribution. |

## Constraints and interactions

- `EMBEDDING_DIM` ↔ `schema/0001_init.sql`: the two must agree;
  changing one without the other is a runtime error or a silent
  mismatch.
- `FORMS` applies to new ingests only.
- `SEC_*_BASE` variables exist for proxying or testing against
  mirrors; the default values are the production SEC endpoints.
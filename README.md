# RAGuessLighter

Retrieval-Augmented Guess Lighter over **SEC EDGAR filings**, in OCaml.

This is a pure vibe-coding proof of concept: built with Qwen 3.8 27B under
almost no supervision, primarily to see how far the model can get on its
own. It went further than expected.

Filings are ingested through the official public EDGAR APIs (no key, fair
access policy), chunked and embedded through any **OpenAI-compatible**
inference server (vLLM, ninfer, llama.cpp, or the cloud), stored in
**PostgreSQL/pgvector**, and searchable with grounded LLM answers.

```
 ingest                                                                  query
 ──────                                                                  ─────
 EDGAR daily-index sitemaps / per-CIK submissions JSON
        │  (accession numbers, gzip XML/JSON)
        ▼
 Archives: filing index page → primary document (.htm)
        │  (HTML, 1–20 MB)
        ▼
 html_text: heading-aware blocks → chunk: size/overlap cuts
        │  (text blocks)
        ▼
 OpenAI-compatible /embeddings ──► pgvector (cosine, HNSW)
                                            │
                                            ▼
        /ask TEXT ◄── OpenAI /chat (grounded prompt) ◄── /search TEXT
```

## Requirements

- **OCaml 5.5.0** + dune ≥ 3.20 (opam switch `raguesslighter`,
  `opam switch .` to install from `raguesslighter.opam`).
- **PostgreSQL 17 + pgvector** — a ready podman stack is provided
  (see below).
- **Any OpenAI-compatible server** for chat + embeddings
  (`OPENAI_BASE_URL`); the app only speaks HTTP to it.

## Setup

```sh
# 1. database (Postgres 17 + pgvector; schema runs on first init)
podman compose up -d

# 2. configuration
cp .env.example .env       # then edit: OPENAI_BASE_URL, models, SEC_USER_AGENT

# 3. build
dune build
```

`.env` is gitignored; every behaviour knob lives there (see
`.env.example` for the full annotated list).

## Usage

### Ingest

```sh
dune exec bin/ingest.exe -- day 2026-08-20        # one business day
dune exec bin/ingest.exe -- backfill 2026-08-01 2026-08-20   # a range (weekends/holidays skipped)
dune exec bin/ingest.exe -- cik 1045810           # one company's recent filings
dune exec bin/ingest.exe -- ticker NVDA           # same, via company_tickers.json
dune exec bin/ingest.exe -- stats                 # store contents
```

Discovery is per-business-day via the **daily-index sitemaps** (the
complete filing set for a day, ~5,000 accessions), *not* the
browse-edgar "current filings" page (a sample of the current day only) —
see [docs/adr/ADR-001-ingest-discovery.md](docs/adr/ADR-001-ingest-discovery.md).
Ingesting is **idempotent**: `(doc_id, chunk_index)` is unique and
already-ingested documents are skipped.

Only the forms in `FORMS` are ingested (default: 10-K/A, 10-Q/A, 8-K/A,
20-F/A, 6-K); `FORMS=ALL` includes registration statements and proxy
filings (~5,000/day vs a few hundred).

### Query

```sh
dune exec bin/query.exe -- search "goodwill impairment" --form 10-K -k 8
dune exec bin/query.exe -- ask "What risks does NVDA disclose about China export controls?"
```

`search` prints the top hits with metadata (company, form, filed date,
section, similarity); `ask` feeds the hits to the LLM with a grounded
prompt and prints the answer with citations. Both accept `--cik`,
`--form` and `--ticker` filters.

### Ad-hoc SQL

No `psql` client is needed on the host: run one in a throwaway container
on the host network (it reaches the same `localhost:5432` the app uses):

```sh
podman run --rm --network host pgvector/pgvector:pg17 psql \
  "postgresql://raguesslighter:raguesslighter@127.0.0.1:5432/raguesslighter" \
  -c "SELECT company, form, count(*) FROM chunks GROUP BY 1, 2;"
```

(Adjust the credentials if your `compose.yaml` / `.env` differ.)

## Testing

```sh
dune build
dune runtest
```

- **Unit tests** (`test/test*.ml`, 160 cases): every library on its own,
  with **fixtures that pin the real SEC and OpenAI wire formats**
  (`test/fixtures/`): real EDGAR index pages (NVDA/AAPL 10-K), a real
  8-K HTML filing, a real daily-index sitemap (gzip), a real submissions
  JSON, `company_tickers.json`, and OpenAI chat/embedding responses.
- **End-to-end test** (`test/e2e.ml`): no network. Two mock HTTP servers
  (EDGAR + OpenAI, `test/mock.ml`) are started in-process; the full
  pipeline runs against them — ticker → CIK → submissions → filing index
  → document → chunks → embeddings → store — plus idempotency, search
  with metadata filters and stats. The e2e test creates and destroys a
  scratch database `raguesslighter_e2e` (the main one is left untouched),
  so Postgres must be reachable at `DATABASE_URL`.

## Project layout

```
bin/    ingest.exe, query.exe (cmdliner CLIs)
lib/    config, net (HTTP client), gz, date, edgar (discovery + parsing),
       html_text, chunk, openai, json, store (pgvector), pipeline
schema/ 0001_init.sql — chunks table + HNSW index (runs on first DB init)
test/   unit + e2e tests, fixture helpers, mock HTTP servers, fixtures/
docs/adr/  ADR-001: ingest discovery via daily-index sitemaps
vendor/ppx_rapper  vendored SQL-query ppx (rapper)
```

## Notes

- **SEC fair access**: static `SEC_USER_AGENT` with contact info,
  ≤ 10 req/s. EDGAR has no API key.
- **Embedding dimension**: `EMBEDDING_DIM` must match the `vector(N)`
  column in `schema/0001_init.sql` (768 = nomic-embed-text).
- **No in-process models**: inference is entirely behind
  `OPENAI_BASE_URL`; swapping vLLM for the cloud changes one line in
  `.env`.
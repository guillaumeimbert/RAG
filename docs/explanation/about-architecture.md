# About the architecture

RAGuesslighter is a retrieval-augmented generator over SEC EDGAR
filings: it stores what companies disclose, retrieves the passages
and exact figures relevant to a question, and hands them to an LLM
that must answer from them. The interesting design question is not
the RAG part — that is a well-trodden path — but what *kind* of
retrieval a document corpus like EDGAR actually needs. This document
gives the tour; the decision records live in
[ADR-001](../adr/ADR-001-ingest-discovery.md) (how filings are
discovered) and [ADR-002](../adr/ADR-002-heterogeneous-retrieval.md)
(why there are two retrieval paths).

## The shape of the system

```
EDGAR ──► discover ──► fetch ──► parse ──┬─► chunk ──► embed ──► chunks (pgvector)
             (sitemaps,    (HTML,    (text,        │
              submissions   XML)      XML)          │
              JSON)                                    ├─► ownership_events
                                                  └──► └─► holdings (SQL)
                                                           │
query ──► search / ask (prose)  +  holders / ask [SQL] (structured)
```

Four stages, each with a single responsibility:

1. **Discovery** (`lib/edgar.ml`) — which filings exist. Two sources:
   the daily-index sitemaps (the *complete* per-business-day filing
   set, for `day`/`backfill`) and the per-CIK submissions JSON (one
   company's history, for `ticker`/`cik`). Why these two and not the
   more famous "current filings" page: ADR-001.
2. **Fetch** (`lib/net.ml`, `lib/gz.ml`) — one HTTP client for
   everything: gzip by magic bytes, a static `User-Agent`, and
   `lwt_ssl` for HTTPS. EDGAR is plain HTTP/1.1 with static content;
   there is deliberately no retry storm, no connection pooling, no
   queue — just fair, sequential politeness (see
   [About SEC fair access](about-sec-fair-access.md)).
3. **Parse** — three converters, one per document family:
   `lib/html_text.ml` (heading-aware text extraction from filing
   HTML), `lib/xml.ml` (a minimal XML walker for the ownership
   filings), and `lib/ownership.ml` (13G/13D/13F field extraction).
4. **Store** (`lib/store.ml`) — PostgreSQL/pgvector. The schema is
   boring on purpose: one table per fact kind
   ([schema reference](../reference/schema.md)).

`lib/pipeline.ml` is the orchestrator: given a filing, it routes it
by form to the prose path or an ownership parser, embeds, upserts,
and reports stats. Per-filing failures are caught and skipped, so one
malformed filing never aborts a day's ingest.

## Why two retrieval paths

EDGAR is a heterogeneous corpus. A 10-K risk factor is prose and
wants fuzzy semantic search; a 13F is a table and wants `ORDER BY
value`. Forcing everything through one embedding is the failure mode
this project set out to fix: the embedding of a 100-row holdings
table is a blob of digits that matches almost nothing, and "what
percentage does X own of Y" answered from fuzzy chunks is a
hallucination risk. So ownership filings are parsed to relational
rows (exact) **and** their narrative is still embedded (qualitative
questions about a 13G's item 2 explanation remain answerable). The
`ask` command blends both when the question is ownership-shaped.
Full argument and limits: [About heterogeneous retrieval](about-heterogeneous-retrieval.md).

## Why the pieces look the way they do

- **Hand-rolled parsers** (`json.ml`, `html_text.ml`, `xml.ml`). The
  EDGAR wire formats are stable and pinned by fixtures; a minimal
  parser over a pinned format is easier to audit than a dependency
  tree, and every one of these parsers has bitten us in exactly the
  way only tests can find (an unbalanced parenthesis, a `>` that was
  never consumed). The cost is real — see the test suite for where it
  shows up — but the dependency surface stays small: `lwt`,
  `cohttp-lwt(-unix)`, `lwt_ssl`, `caqti` (Postgres), `cmdliner`,
  `re`.
- **SQL through ppx** (`vendor/ppx_rapper`). Queries are string
  literals in the source, checked at compile time against a hand
  written row type. No ORM, no query builder, no abstraction layer
  between the app and the actual SQL that runs.
- **One `.env`, read per invocation.** There is no daemon; every
  command is a short-lived process. This makes every run reproducible
  and every test independent, at the price of re-reading config and
  re-opening the DB each time — a non-issue at this scale.
- **The in-process mock servers** (`test/mock.ml`) exist because the
  e2e test must be airtight and offline: the exact same pipeline code
  runs against fixtures that are *actual captured SEC and OpenAI
  responses*, so "the tests pass" means "the wire formats are still
  what we expect". See [About the test suite](about-testing.md).

## Where things are

| Module | Responsibility |
|---|---|
| `lib/config.ml` | `.env` parsing, `forms_allow` |
| `lib/net.ml` | HTTP client (gzip, user agent, ssl) |
| `lib/gz.ml` | gzip inflate (magic-byte detected) |
| `lib/date.ml` | date parsing/formatting |
| `lib/edgar.ml` | discovery endpoints, index parsing, submissions JSON, ticker→CIK |
| `lib/html_text.ml` | filing HTML → heading-aware text blocks |
| `lib/chunk.ml` | block → chunk (size/overlap) |
| `lib/openai.ml` | embeddings + chat (OpenAI-compatible) |
| `lib/json.ml` | minimal JSON parser |
| `lib/xml.ml` | minimal XML walker (local names, entities) |
| `lib/ownership.ml` | 13G/13D/13F parsing, form normalisation |
| `lib/store.ml` | pgvector store: upsert, search, holders, positions, stats |
| `lib/pipeline.ml` | ingest orchestration, per-filing fault isolation |
| `bin/ingest.ml` | ingest CLI (cmdliner) |
| `bin/query.ml` | query CLI: search, ask (hybrid), holders |

The project is small enough that the module list *is* the
architecture; when it stops being true, the README's layout section
has already been moved here for a reason.
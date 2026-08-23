# ADR-002 — Heterogeneous retrieval: prose RAG + structured SQL for ownership

**Status:** accepted (2026-08-22)

## Context

RAGuesslighter is a prose RAG over EDGAR: filings are converted to text,
chunked, embedded, and retrieved by cosine similarity. That is the right
tool for *narrative* disclosures (risk factors, MD&A, 8-K descriptions),
but **ownership filings are not narrative** — they are tabular:

- **13G / 13D** (Schedule 13G/13D): a reporting person crosses the 5%
  beneficial-ownership threshold of an issuer. The answer to "who holds
  X% of Y and since when" is a small set of exact fields (filer, issuer,
  class, shares, percent, passive vs active, event date), repeated per
  amendment.
- **13F-HR**: an institutional manager's quarterly holdings table —
  hundreds of rows of (issuer, CUSIP, class, shares, value, discretion,
  voting). "NVIDIA's top positions" is a `SELECT ... ORDER BY value`.

Pushing these through the prose path produces three failure modes:
(a) the embedding of a 13F information table is a 100-row blob of digits
that matches almost nothing; (b) a question about an exact percentage is
answered by the LLM from fuzzy chunks and can hallucinate the number;
(c) the "latest position" semantics (amendments, quarterly re-filings)
have no vector representation at all.

Meanwhile SEC publishes these filings as **structured XML** (`primary_doc.xml`
plus, for 13F, a separate `information_table.xml`, both at the
accession root on `Archives/edgar/data/`), which can be parsed exactly.

This was also the PoC question of the project: *can the model design and
build a retrieval system that routes different filing types to different
pipelines?* (Yes — see "PoC note".)

## Decision

1. **Route by filing type at ingest** (`Pipeline.ingest_job`):
   - `Ownership.classify form` → `Prose` (10-K/10-Q/8-K/…): unchanged
     HTML → text → chunk → embed path into `chunks`.
   - `Form13g` / `Form13d`: fetch the raw `primary_doc.xml`, parse the
     cover (filer, issuer, class, shares, percent, passive, event date)
     into `ownership_events` rows. The filing's *narrative* (item 2
     explanation, items 6/7, certification) additionally goes through the
     prose path as a single chunk (`"<Form> — items & comments"`), so it
     stays answerable by the LLM for qualitative questions.
   - `Form13f`: fetch `primary_doc.xml` (cover: filer, period, total
     value, amendment flag) **and** `information_table.xml` (the holdings
     table, exploded to one `holdings` row per position). A missing
     information table does not block the filing (zero positions,
     warning).
2. **Schema** (`schema/0002_ownership.sql`): two new tables,
   `ownership_events` and `holdings`. NUMERIC/BIGINT columns are read
   back as `float8` via `COALESCE(col::float8, -1)` (−1 = not stated) to
   keep the OCaml row types simple. The 13F issuer CIK is resolved
   **best-effort** by name against `company_tickers.json` at ingest time
   (`issuer_cik = ''` when unresolved — the row is still retrievable by
   name); resolution is lazy/cached per process.
3. **Structured query path** (`store.ml`): `holders_of ~subject_cik`
   (latest event per filer via `ROW_NUMBER()`, with the previous event's
   shares/percent so amendments show a delta) and `positions_of
   ~issuer_cik ~issuer_name` (latest 13F report per filer; CIK match
   when known, `ILIKE` on issuer name otherwise). `query.exe holders
   --subject <ticker|CIK>` prints both sections.
4. **Hybrid `ask`** (`query.ml`): the question is screened by a keyword
   regex (holders, ownership, stake, institutional, portfolio, 13f/13d/
   13g, "who owns/holds", percent…). When it matches, alphabetic words of
   the question (stopwords dropped, first 8) are resolved to CIKs
   (ticker → exact normalised name → **unambiguous name prefix**, max 2
   entities), and the resulting `holders_of`/`positions_of` rows are
   appended to the LLM prompt as a `[SQL]` evidence block. The LLM may
   cite it; prose hits are still attached as usual. Non-ownership
   questions take the pure prose path, unchanged.
5. **Idempotency**: `filing_exists` = the accession appears in *any* of
   the three tables (`chunks`, `ownership_events`, `holdings`); a
   re-ingest skips it. Per-filing faults (`Lwt.catch`) skip that filing
   with a warning instead of aborting the day.
6. **XML**: the in-house minimal XML walker (`lib/xml.ml`) — local-name
   matching (namespace prefixes stripped), entity decoding, comments/
   declarations skipped. SEC 13G/13D/13F XML is well-formed and shallow;
   a general-purpose library (`xmlm`) was not worth the dependency.

## Consequences

- Two retrieval paths, one store: prose questions unchanged, ownership
  questions get **exact** figures (verified live: "What percentage of
  Nebius does NVIDIA own?" → "9.30% — 22,256,412 shares — per its 13G
  filing [SQL]", with the 13F position of 1,190,476 shares /
  $328,773,757 also cited).
- Cost: +2 tables, +1 XML parser (~300 LOC), +1 routing decision in the
  pipeline. Ingest of an ownership filing is 1–2 small XML fetches
  instead of a multi-MB HTML document.
- Limits (v1): name-based 13F issuer resolution misses name variants
  (ADR filings, "ARM HOLDINGS PLC" ≠ "ARM Holdings plc"); the `ask`
  router is a keyword regex, not an LLM classifier; 13D multi-person
  `reportingPersonInfo` is flattened to one row per person; Form 3/4/5
  (insider transactions) are not parsed.

## PoC note

The model (Qwen 3.8 27B, supervised only at the "implement in one pass"
gate) produced: the routing design above, the two-table schema, the
separate 13G vs 13D parsers (13G = single filer, 13D = multiple
reporting persons), the 13F two-document fetch, the `ROW_NUMBER()`
delta query, the hybrid `ask` evidence block, and the fixtures + unit +
e2e tests pinning real captured SEC XML. Human contribution: the goal
statement, review of the live-verification transcript, and the
test-failure debug loop (the model's first XML walker had an unbalanced
parenthesis in a `Lwt_list.fold_left_s` and a `>` that was never
consumed; both found by the test suite, not by review).
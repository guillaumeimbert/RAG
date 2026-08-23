# About heterogeneous retrieval

A RAG system makes a bet: that embedding text and doing cosine
similarity is the right way to find what a question is about. That
bet works for the part of EDGAR that is written like an essay — and
EDGAR is mostly essays. But a substantial minority of filings are
**not** essays, and this project's central design decision is to stop
pretending they are.

## Why one retrieval path is not enough

Three disclosure families dominate ownership questions:

- **13G / 13D** — "I crossed 5% of this issuer." The answer to the
  question is a handful of exact fields: who, what, how many shares,
  what percent, passive or active, since when. The narrative part
  (item 2, the statement that the purchase was for investment
  purposes only) is boilerplate in most 13Gs.
- **13F** — "Here is everything we held at quarter end." Hundreds of
  rows of (issuer, CUSIP, class, shares, value, discretion, voting).
- **Form 3/4/5** — insider transactions. (Out of scope in v1.)

Push these through the prose path and you get three distinct failure
modes:

1. **The embedding is meaningless.** A 100-row information table
   becomes a chunk of digits and acronyms. Cosine similarity against
   it is noise; it will rank near the bottom of every query, or
   inexplicably high next to any other table-shaped chunk.
2. **Exact questions get fuzzy answers.** "What percentage of Nebius
   does NVIDIA own?" answered from a fuzzy 13G chunk is an
   approximation with a confidence the model did not earn. The LLM
   will happily say "approximately 9%" when the filing says 9.30% and
   22,256,412 shares.
3. **Time semantics have no representation.** "The latest position"
   means: for each filer, the most recent report; for amendments, the
   latest event *and* the delta versus the previous one. That is a
   `ROW_NUMBER() OVER (PARTITION BY filer ORDER BY period DESC)`, not
   a similarity score.

Meanwhile the SEC publishes all of this as **well-formed XML**
(`primary_doc.xml`, `information_table.xml` at the accession root),
so the exact fields are available for free — the only question is
whether to parse them.

## The design

Route by filing type at ingest, keep both paths available at query:

- **Prose path** (unchanged): HTML → text → chunks → embeddings →
  cosine search → grounded LLM answer.
- **Structured path** (new): raw XML → exact rows in
  `ownership_events` / `holdings` → SQL queries.
- **Overlap on purpose**: the 13G/13D *narrative* (items & comments)
  is also chunked and embedded. The structured path answers "how
  much, exactly"; the prose path answers "what did they say". A
  filing can live in both.
- **Hybrid `ask`**: when a question is ownership-shaped (a keyword
  screen — deliberately cheap and inspectable, not an LLM
  classifier), the companies named in the question are resolved to
  CIKs, their exact rows are pulled, and they are appended to the LLM
  prompt as a `[SQL]` evidence block. The model then answers with
  numbers it was *given*, and the sources list carries the `[SQL]`
  marker so a human can see which path the answer came from.

The verified end state: "What percentage of Nebius does NVIDIA own?"
returns **"9.30% of Nebius Class A Ordinary Shares (22,256,412
shares), per the latest 13G data [SQL]"**, with the 13F position
($328,773,757 / 1,190,476 shares) also cited — figures the prose path
alone could not guarantee.

## What the routing buys, and what it costs

**Buys:** exactness for the exact questions; a `holders` command that
needs no LLM at all (fast, cheap, deterministic); a clean place to
add the next structured family (Form 4 tables, 13F amendments with
delta queries, cross-filer aggregation) without touching the prose
pipeline.

**Costs:** a second schema, a second parser family, a routing decision
in the pipeline, and the classic hybrid-system problem — the boundary
between the two paths. Here the boundary is a keyword list; questions
that are ownership questions *without* the keywords take the prose
path and get the fuzzy answer. That is an acceptable v1 trade: the
keyword screen is visible, testable, and easy to extend, whereas an
LLM classifier would add a model call to every query and make the
boundary opaque.

## Known limits (v1)

- **13F issuer identity** is resolved by name-matching against the
  tickers file; unresolved issuers get `issuer_cik = ''` and are
  retrievable by name only (`ILIKE`). ADR filings and name variants
  ("ARM HOLDINGS PLC" vs "ARM Holdings plc") will not match.
- **13D multi-person groups** are flattened to one event row per
  reporting person.
- **Form 3/4/5** are not parsed.
- The **`ask` screen** resolves at most two companies per question.

These are documented in [ADR-002](../adr/ADR-002-heterogeneous-retrieval.md),
along with the decision history and the project's PoC note (this was
also the experiment: can a model, given the goal, design and build
exactly this routing?).
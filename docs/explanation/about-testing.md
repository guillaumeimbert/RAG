# About the test suite

The test suite answers one question: *if EDGAR changed the shape of
its XML, or the inference server changed the shape of its JSON, or
our SQL drifted from the schema — when would we notice?* The design
goal is that the answer is "in this repository, before any user".

## The threat model

RAGuesslighter sits on top of three external contracts it does not
control:

1. **EDGAR wire formats** — sitemap XML, submissions JSON, filing
   index HTML, ownership XML (13G/13D/13F).
2. **The OpenAI-compatible API** — embeddings and chat request/
   response shapes.
3. **The database schema** — `schema/*.sql` and the SQL the app
   actually runs.

None of these changes often. When one does, it is usually silent: a
renamed field, a new wrapper element, a changed default. The classic
failure is a pipeline that "works" and writes garbage.

## The two layers

**Unit tests** (`test/test*.ml`, 202 cases) run each module against
**fixtures that are actual captured responses**, not synthetic ones:
real EDGAR index pages (NVDA/AAPL 10-K), a real 8-K HTML filing, a
real daily-index sitemap in both plain and gzip encoding, a real
submissions JSON, real 13G/13D/13F XML filings (NVDA→Nebius 13G,
GameStop 13D, NVDA 13F cover + information table), `company_tickers.json`,
and real OpenAI chat/embedding responses. A unit test passing means
the parser still understands *that document, byte for byte, plus the
documented variations*. The fixtures are the pin: if EDGAR changes
the format, the fixture still parses (good — the parser is
robust) or it fails with a diff you can read (better — you know
exactly what changed).

**End-to-end test** (`test/e2e.ml`, no network) runs the *entire*
pipeline — ticker → CIK → submissions → filing index → document →
chunks → embeddings → store → search → stats → ownership XML →
`ownership_events`/`holdings` → SQL `holders`/`positions` — against
two **in-process mock HTTP servers** (`test/mock.ml`) that serve the
captured fixtures, and against a **scratch Postgres database**
(`raguesslighter_e2e`, created and destroyed by the test; the main
store is untouched). The e2e test also verifies idempotency
(re-ingest skips) and applies the schema files itself.

What a green e2e does *not* verify: that the **live** SEC still
answers, that your inference server still serves, or that the model
still answers sensibly. Those are live checks, not tests — the
documented procedure is a real `ingest ticker NVDA` plus an `ask`,
and the ADRs record the live verifications that shaped the design.

## Why mocks instead of the network in e2e

Three reasons, in order of importance:

- **Determinism.** EDGAR's "recent filings" change daily; a test that
  fetches live data is a test that fails on Monday because of
  Saturday.
- **Civility.** The e2e test runs on every `dune runtest`; pointing
  it at the SEC would mean every developer's every test run is SEC
  traffic.
- **The point of e2e is the pipeline, not the network.** HTTP is
  tested separately (unit tests on `net.ml` against a local mock),
  so the e2e's mock can serve fixtures with zero HTTP fidelity
  beyond what the pipeline actually uses.

## Where the hand-rolled parsers pay rent

The suite has, in the past, caught parser bugs that review did not:
an XML start-tag `>` never consumed (every text node started with a
`>`), a comment handler that silently ended its enclosing element, an
entity handler that never advanced the cursor (infinite loop on
`<a>&amp;</a>`). These are exactly the bugs that a pinned-fixture
test catches on the first run after a change, and exactly the bugs
that would otherwise ship as "the 13G parser works on the fixture we
remember". The lesson for extending the parsers: **write the fixture
test first, from a captured real document**, and let it fail until
the parser is right.
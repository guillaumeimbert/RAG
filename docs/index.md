# Documentation

RAGuesslighter's documentation follows the
[Diátaxis](https://diataxis.fr) framework: four kinds of help, each
serving a different need. Pick the quadrant that matches what you're
doing.

## Tutorials — learning by doing

*For: "I'm new here and I want to know if this works."* A guided
lesson; follow every step, you will finish with a working store.

- [Your first ingest and first question](tutorials/first-ingest.md)

## How-to guides — solving a task

*For: "I know what I want to do; tell me how."* Task-oriented,
assumes the tutorial was done (or the equivalents).

- [Ingest filings](how-to/ingest.md) — one company, one day, a range, more forms
- [Query ingested filings](how-to/query.md) — search, ask, filters
- [Query ownership (13G/13D/13F)](how-to/ownership.md) — who holds what, exactly
- [Inspect and manage the database](how-to/database.md) — psql, schema, resets
- [Point the app at an inference server](how-to/inference.md) — chat, embeddings, model changes
- [Run the test suite](how-to/testing.md)

## Reference — looking up facts

*For: "I need the exact flag / setting / column."* Describes the
machinery, no opinions, consulted rather than read.

- [CLI reference](reference/cli.md) — every command and option
- [Configuration reference](reference/configuration.md) — every `.env` variable
- [Database schema reference](reference/schema.md) — tables, columns, indexes
- [EDGAR source reference](reference/edgar-sources.md) — endpoints, identifiers, URL layouts

## Explanation — understanding the why

*For: "Can you tell me about …?"* Readable away from the machine.

- [About the architecture](explanation/about-architecture.md)
- [About heterogeneous retrieval](explanation/about-heterogeneous-retrieval.md) — why prose RAG and SQL live side by side
- [About SEC fair access](explanation/about-sec-fair-access.md)
- [About the test suite](explanation/about-testing.md)

Decision records: [ADR-001 — ingest discovery](adr/ADR-001-ingest-discovery.md),
[ADR-002 — heterogeneous retrieval](adr/ADR-002-heterogeneous-retrieval.md).
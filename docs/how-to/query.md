# How to query ingested filings

Query commands are `dune exec bin/query.exe -- <command>` (abbreviated
`query.exe` below). `search` and `ask` work over the prose store;
`holders` works over the structured ownership tables and needs no
inference server.

## Find passages on a topic

```sh
query.exe search "goodwill impairment" -k 8
```

Each hit prints a rank, the cosine similarity (higher = closer), the
filing metadata (company, ticker, form, filed date), and a snippet.
To stop at the passages you recognise, lower `-k`; to widen the net,
raise it (default `TOP_K` from `.env`).

## Restrict the search

Filter by company or form (repeatable constraints are single-valued
here — one `--ticker`, one `--cik`, one `--form` per run):

```sh
query.exe search "export controls" --ticker NVDA --form 10-K -k 5
query.exe search "supply chain" --cik 0001045810
query.exe search "dividends" --form 8-K
```

Filters combine with `AND`. If nothing matches, drop the most
restrictive filter first.

### Reject low-quality matches

By default `search` always returns the nearest `TOP_K` hits, however
poor. Set `MIN_SIMILARITY` in `.env` (e.g. `0.5`) to drop hits whose
cosine similarity is below the floor — an unrelated query then prints
`no results` instead of the nearest, least-relevant passages. `ask`
uses the same floor, so it will say there is no supporting material
rather than ground an answer in off-topic passages. Tune the value
against your embedding model's score distribution (see
[configuration](../reference/configuration.md)).

## Ask a question

```sh
query.exe ask "What risks does NVDA disclose about China export controls?"
```

The app retrieves the top passages (same filters as `search`), sends
them to the chat model with a grounded prompt, and prints the answer
followed by the numbered passages it used. Rules of thumb:

- Ask one question at a time, in the vocabulary of the filings.
- Keep `-k` at or above the default for broad questions; the model
  needs context, not one snippet.
- The answer should cite its sources. If it answers from general
  knowledge instead, the passages were off-topic — tighten the
  question or add `--ticker`/`--form`.

Ownership questions are handled differently — see
[how to query ownership](ownership.md).

## Get the raw passages (no LLM)

`search` with no `ask` is the pure-retrieval path: same ranking, no
model call, instant. Use it to inspect what the store actually
contains for a query before deciding how to phrase a question.
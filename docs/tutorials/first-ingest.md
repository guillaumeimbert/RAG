# Tutorial: your first ingest and first question

In this tutorial you will ingest NVIDIA's SEC filings into a local
vector store and ask it questions. By the end you will have a store
that returns passages from real 10-K/10-Q/8-K filings, answers
questions with grounded citations, and reports exact 13G/13F
ownership figures — and you will have done every step yourself,
watching what happens at each one.

You need about 15 minutes and a machine with:

- **OCaml 5.5.0 + dune** (opam switch `raguesslighter` — see
  [Requirements](../../README.md#requirements))
- **podman** (for the database container)
- **A running OpenAI-compatible inference server** for chat and for
  embeddings (vLLM, llama.cpp, ninfer, or the cloud — any server with
  `/embeddings` and `/chat/completions`)

You do not need to understand how any of it works to follow along.
You will learn it by doing.

---

## 1. Start the database

From the repository root:

```sh
podman compose up -d
```

You will see a line like:

```
time="..." level=info msg="raguesslighter-db started"
```

The container starts PostgreSQL 17 with the pgvector extension and
creates the schema automatically on its very first run (a warning
about the HNSW index may appear if your embedding dimension is above
2000 — that is normal, and retrieval simply uses a sequential scan).

Check it:

```sh
podman compose ps
```

You will notice `raguesslighter-db` listed as **healthy** after a few
seconds.

If the container does not start, the usual cause is port 5432 being
taken by another Postgres. Stop it (`podman compose down`) once the
other Postgres is off, and start again.

---

## 2. Configure the app

```sh
cp .env.example .env
```

Then open `.env` in an editor and set **three things**:

1. `SEC_USER_AGENT` — your name and email. The SEC requires a
   contact address in every request (fair access policy).
2. `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `LLM_MODEL` — your chat
   server, e.g. `http://localhost:1234/v1`, a key (local servers
   usually accept any non-empty string), and the model name it
   serves.
3. `EMBEDDING_MODEL` and `EMBEDDING_DIM` — the embedding model and
   its output dimension. If your embeddings come from a different
   server than your chat, also set `OPENAI_EMBED_BASE_URL` and
   `OPENAI_EMBED_API_KEY`.

Save the file. You do not need to restart anything — the app reads
`.env` on every run.

---

## 3. Build

```sh
dune build
```

You will see dune compile a handful of files. When it finishes, the
last line is empty and your shell prompt returns — no `Error:` lines
means success. (On subsequent runs dune does nothing and returns
immediately, because nothing changed.)

---

## 4. Ingest one company

Now the moment you started for:

```sh
dune exec bin/ingest.exe -- ticker NVDA
```

This tells the app to look up NVIDIA's CIK, fetch its recent filings
from EDGAR (10-Ks, 10-Qs, 8-Ks and the ownership schedules 13G/13D/
13F-HR), convert them, and embed every chunk. On a local GPU the run
takes a few minutes; on a cloud API longer still. Do not interrupt it.

When it finishes you will see one summary line, like:

```
NVDA (CIK 0001045810)  docs=90 chunks=4767 events=3 positions=63 skipped=0 failed=0
```

The numbers depend on how many filings the company has and on when
you run this — yours will be different, but you should see a
non-zero `docs` and `chunks`, and probably a few `ownership
events` / `13F positions` too.

Notice the two kinds of results in that one line: `docs`/`chunks`
are the **prose** path (embedded text), while `ownership events` and
`13F positions` are the **structured** path (exact figures parsed
from 13G/13D/13F XML). You will use both.

Confirm the store:

```sh
dune exec bin/ingest.exe -- stats
```

```
documents:        90
chunks:           4767
ownership events: 3
13F positions:    63
```

(Your numbers will differ.)

---

## 5. Find a passage

```sh
dune exec bin/query.exe -- search "data center capacity expansion" --ticker NVDA -k 3
```

You will get up to three numbered hits, each with a similarity score,
the filing metadata, and a snippet:

```
[1] 0.551  NVIDIA CORP (NVDA) — 10-K, filed 2026-02-25
     with Rule 10b-18 of the Exchange Act, subject to market conditions, …
[2] 0.527  NVIDIA CORP (NVDA) — 10-Q, filed 2026-05-20
     structured share repurchase agreements in compliance with Rule 10b-18, …
[3] 0.523  NVIDIA CORP (NVDA) — 10-K, filed 2026-02-25
     actions, additional reporting requirements and/or oversight, …
```

Notice each hit names the **form** and **filing date** — the same
filing can contain many chunks, and the search returns the chunks
that matched your query, not whole documents.

---

## 6. Ask a question

```sh
dune exec bin/query.exe -- ask "What risks does NVDA disclose about China export controls?"
```

The app takes the top passages, hands them to the chat model with a
grounded prompt, and prints the answer followed by the passages it
used, as a numbered `Sources:` list. The answer should cite the
filings rather than talk in the abstract — that is the "grounded"
part. If the model answers with general knowledge instead, try a more
specific question or raise `-k`.

---

## 7. Ask an ownership question

Now the structured path. Run:

```sh
dune exec bin/query.exe -- ask "What percentage of Nebius does NVIDIA own?"
```

Because the question is about ownership, the app additionally pulls
the **exact** 13G/13F rows from the database and hands them to the
model. The answer should contain precise figures — not an
approximation:

```
NVIDIA owns **9.30% of Nebius Class A Ordinary Shares** (22,256,412 shares), per the latest 13G data [SQL].
```

and the sources list ends with a line:

```
  [SQL] structured ownership data (13F/13G/13D, exact figures)
```

That `[SQL]` marker is your signal that the numbers came from the
structured tables, not from fuzzy text.

You can also get the raw structured answer without the LLM at all:

```sh
dune exec bin/query.exe -- holders --subject NBIS
```

```
Ownership of NBIS (CIK 0001513845), from ingested 13G/13D/13F filings:

  13G/13D significant holders (latest event per filer):
  NVIDIA Corporation (13G, event 2026-07-13, filed 2026-07-20, passive): 9.30% of Class A Ordinary Shares — 22256412 shares
  13F institutional positions (latest report per filer):
  NVIDIA CORP (period 2026-06-30): $328773757, 1190476 shares (SHS CLASS A)
```

Two sections: who crossed the 5% threshold (13G/13D), and what
institutional managers report holding (13F). This command needs no
inference server at all — it is pure SQL.

---

## What you have built

A working retrieval-augmented store over one company's filings, with
two complementary paths:

- **Prose** (steps 5–6): embedded chunks, cosine search, grounded LLM
  answers with citations.
- **Structured** (step 7): exact ownership figures from 13G/13D/13F,
  queryable in SQL and attached to LLM answers when the question is
  ownership-shaped.

If any step above failed, the most common causes are:

- `connection refused` to the database → `podman compose ps` — the
  container is not running.
- HTTP 403 from the SEC → `SEC_USER_AGENT` is missing or has no
  contact address.
- errors talking to the inference server → check `OPENAI_BASE_URL`
  (it must end in `/v1`) and that the server is up.

---

## Where to go next

- [How-to guides](../index.md) — do real things: ingest other
  companies, backfill date ranges, query ownership, inspect the
  database.
- [Reference](../index.md) — every `.env` setting, every CLI flag,
  the database schema.
- [Explanation](../index.md) — how the whole thing fits together, and
  why it is built the way it is.
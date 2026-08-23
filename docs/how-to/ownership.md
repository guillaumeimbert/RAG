# How to query ownership (13G / 13D / 13F)

The structured path answers "who holds what, exactly". It reads the
`ownership_events` and `holdings` tables directly — no inference
server needed.

## Prerequisite: the ownership filings must be ingested

Ownership data only exists for companies ingested with `13G`, `13D`
and `13F-HR` in `FORMS` (the default includes them). If
`holders` says no data, ingest the subject (and, for 13F, the
*filers* are funds — their 13Fs are picked up when the funds' own
filings are in scope) or check
[how to ingest filings](ingest.md#ingest-more-or-fewer-forms).

## List the owners of a company

```sh
query.exe holders --subject NBIS
```

`--subject` accepts a ticker, a company name, or a CIK. Output, two
sections:

```
Ownership of NBIS (CIK 0001513845), from ingested 13G/13D/13F filings:

  13G/13D significant holders (latest event per filer):
  NVIDIA Corporation (13G, event 2026-07-13, filed 2026-07-20, passive): 9.30% of Class A Ordinary Shares — 22256412 shares
  13F institutional positions (latest report per filer):
  NVIDIA CORP (period 2026-06-30): $328773757, 1190476 shares (SHS CLASS A)
```

Reading the lines:

- **13G/13D section** — one row per holder (filer), showing the
  *latest* event for that holder: form, event date, filing date, `passive` (13G)
  or active (13D), the percent of the class and the share count. When
  the holder has an earlier event on file (e.g. the latest event is an
  amendment), the previous event's figures are shown in parentheses:
  `… (prev event: 9.10%, 21021846 sh)`.
- **13F section** — one row per institutional filer, from its *latest*
  report: value in USD, shares, and the class as stated in the
  filing.

Rows where the filing did not state a figure print `not stated`.
`-l` caps rows per section (default 10).

## Ask an ownership question through the LLM

```sh
query.exe ask "What percentage of Nebius does NVIDIA own?"
```

Questions containing ownership vocabulary (holders, ownership, stake,
institutional, portfolio, 13f/13d/13g, percent, "who owns/holds")
trigger the hybrid path: the app resolves the companies named in the
question, pulls their `holders`/`positions` rows, and hands them to
the model as a `[SQL]` evidence block alongside the usual prose
hits. The answer cites exact figures and the sources list ends with:

```
  [SQL] structured ownership data (13F/13G/13D, exact figures)
```

Tips:

- Name the companies plainly ("Nebius", "NVIDIA"); resolution tries
  ticker, exact name, then an unambiguous name prefix.
- At most 2 companies are resolved per question; name the subject and
  the holder, nothing else.
- If the `[SQL]` block is missing, the keyword screen did not fire or
  no candidate resolved — fall back to `holders --subject`.

## What the structured path covers

- **13G / 13D** (Schedule 13G/13D): 5% beneficial-ownership
  statements, including amendments (each amendment is an event row;
  the query keeps the latest per filer).
- **13F-HR**: quarterly institutional holdings — one row per
  (filer, position) in the latest report.

Not covered (v1): Forms 3/4/5 (insider transactions), 13F issuer
identification beyond name-matching, and 13D multi-person groups are
flattened to one row per person.
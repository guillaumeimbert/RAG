# About SEC fair access

The SEC's EDGAR system has no API key and no paywall — but it does
have an enforcement policy, and a RAG ingester is exactly the kind of
client that policy exists to police. This page records what we
verified live and how the app behaves accordingly.

## What the policy requires

From the SEC's
[fair access](https://www.sec.gov/os/fair-access) page: identify your
application with a **static `User-Agent` containing contact
information**, and stay at or under **10 requests per second**. The
SEC operates the servers for public disclosure, not for
scraping-arms-races; the policy is the social contract that keeps the
endpoints open to everyone.

## What we observed

Verified live against the production endpoints in 2026-08:

- **Anonymous or generic clients are blocked.** `curl` and default
  Python `urllib`/`requests` User-Agents receive **HTTP 403** from
  the SEC endpoints. The block is on the User-Agent, not the IP —
  the same machine, with a proper identifying User-Agent, gets 200s
  indefinitely.
- **The daily-index sitemaps are the complete daily set** (~5,000
  accessions per business day in 2026-08), but they are served in
  their identity (uncompressed) form unless the client asks:
  `Accept-Encoding: gzip` turns a ~1.08 MB sitemap into ~35 KB —
  roughly a 30× reduction in the bytes every client has to move.
- **The Archives are static.** Filing HTML and raw XML under
  `Archives/edgar/data/` are immutable once published; there is no
  cost to fetching a document twice and no reason not to cache.
- **Scale math.** A single company's recent history is a few hundred
  documents; a full business day matching the default form set is a
  few hundred; `FORMS=ALL` for a day is ~5,000 index pages plus one
  document fetch per filing. At the 10 req/s ceiling, a full `ALL`
  day is a lower bound of ~10 minutes of polite fetching before
  parsing and embedding are even considered.

## How the app behaves

- One static `User-Agent` from `SEC_USER_AGENT`
  (`Your Name <you@example.com>`) on every request to the SEC.
  There is no override-by-env for per-request variation — variation
  is how you look like a scraper.
- Sequential, in-order fetching; no parallel fan-out, no retry storm.
  Failures surface as per-filing skips (with the accession in the
  log), never as hammering the endpoint.
- `Accept-Encoding: gzip` is sent where it helps; the client
  decodes by magic bytes, so endpoints that answer uncompressed
  still work (the test suite pins both encodings).
- Ticker→CIK and the tickers file are **cached per process**, so a
  command that touches the same reference data fetches it once.

## Why this matters for a RAG project specifically

An ingester is *structural* load on EDGAR: unlike a human reader, it
will touch every filing of a company or of a day, repeatedly during
backfill. The failure mode of ignoring fair access is not just being
blocked — it is degrading the service for the next user, on a
system that publishes what regulators and markets depend on. The
10 req/s ceiling and the identifying User-Agent are the entire
cost of keeping the endpoints available; they are not a bottleneck
at this project's scale.
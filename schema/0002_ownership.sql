-- 0002_ownership.sql — structured ownership data (13F / 13G / 13D)
--
-- Narrative disclosures (10-K/10-Q/8-K/...) go to [chunks] (vector
-- retrieval). Ownership disclosures are *structured* filings: they are
-- parsed from their raw XML into relational rows and retrieved with SQL
-- (see lib/ownership.ml). The two retrieval paths are combined by
-- [query.exe ask], which attaches structured evidence to the prose hits
-- when the question is ownership-shaped.

-- One row per (filer, subject, class) of a 13G/13D beneficial-ownership
-- statement. Amendments add rows with the same (filer, subject, class)
-- and a later event date: the [holders] query keeps the latest per holder
-- and reports the change versus the previous event.
CREATE TABLE IF NOT EXISTS ownership_events (
    event_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    accession     TEXT   NOT NULL,               -- filing accession number
    form          TEXT   NOT NULL,               -- normalised: 13G, 13G/A, 13D, 13D/A
    event_date    DATE   NOT NULL,               -- date the 5% threshold event occurred
    filed_at      DATE   NOT NULL,
    filer_cik     TEXT   NOT NULL,               -- reporting person / filer (10-digit padded)
    filer_name    TEXT,
    subject_cik   TEXT   NOT NULL,               -- issuer whose shares are held (10-digit padded)
    subject_name  TEXT,
    subject_cusip TEXT,
    class         TEXT   NOT NULL DEFAULT '',    -- securities class (e.g. "Common Stock")
    shares        NUMERIC,                       -- aggregate beneficially owned
    percent       NUMERIC,                       -- percent of class
    passive       BOOLEAN NOT NULL DEFAULT false,-- 13G (passive) vs 13D (active)
    is_amendment  BOOLEAN NOT NULL DEFAULT false,
    index_url     TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (accession, filer_cik, subject_cik, class)
);

CREATE INDEX IF NOT EXISTS ownership_events_subject_idx
    ON ownership_events (subject_cik, event_date DESC);
CREATE INDEX IF NOT EXISTS ownership_events_filer_idx
    ON ownership_events (filer_cik, event_date DESC);

-- One row per 13F holdings-table position (the "information table",
-- exploded). Amendments re-file the full table under a new accession.
CREATE TABLE IF NOT EXISTS holdings (
    accession     TEXT   NOT NULL,               -- 13F filing accession number
    filer_cik     TEXT   NOT NULL,               -- the filer (e.g. a fund, 10-digit padded)
    filer_name    TEXT,
    period        DATE   NOT NULL,               -- periodOfReport (quarter end)
    filed_at      DATE   NOT NULL,
    issuer_name   TEXT   NOT NULL,               -- as stated in the 13F
    issuer_cusip  TEXT   NOT NULL DEFAULT '',
    issuer_cik    TEXT   NOT NULL DEFAULT '',    -- resolved by name against
                                                 -- company-tickers.json; '' when unresolved
    class         TEXT   NOT NULL DEFAULT '',
    value_usd     BIGINT,
    shares        NUMERIC,
    prnamt_type   TEXT   NOT NULL DEFAULT '',    -- SH / PRN / UNIT
    discretion    TEXT,                          -- investment discretion (SOLE, SHARED, ...)
    vote_sole     NUMERIC,
    vote_shared   NUMERIC,
    vote_none     NUMERIC,

    PRIMARY KEY (accession, issuer_cusip, class, prnamt_type)
);

CREATE INDEX IF NOT EXISTS holdings_issuer_idx ON holdings (issuer_cik, period DESC);
CREATE INDEX IF NOT EXISTS holdings_filer_idx  ON holdings (filer_cik, period DESC);
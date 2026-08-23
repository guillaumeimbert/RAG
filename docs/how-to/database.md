# How to inspect and manage the database

No `psql` client is needed on the host — run one in a throwaway
container on the host network (it reaches the same `localhost:5432`
the app uses):

```sh
podman run --rm --network host pgvector/pgvector:pg17 psql \
  "postgresql://raguesslighter:raguesslighter@127.0.0.1:5432/raguesslighter"
```

(Adjust the credentials if your `compose.yaml` / `.env` differ.) For
one-off queries append `-c "SELECT …"`:

```sh
podman run --rm --network host pgvector/pgvector:pg17 psql \
  "postgresql://raguesslighter:raguesslighter@127.0.0.1:5432/raguesslighter" \
  -c "SELECT company, form, count(*) FROM chunks GROUP BY 1, 2 ORDER BY 3 DESC;"
```

Useful checks:

```sql
-- how much data, where
SELECT count(*) AS chunks, count(DISTINCT doc_id) AS docs FROM chunks;
SELECT count(*) AS events FROM ownership_events;
SELECT count(*) AS positions FROM holdings;

-- which forms are in the prose store
SELECT form, count(*) FROM chunks GROUP BY form ORDER BY 2 DESC;

-- recent ingest activity
SELECT max(created_at) FROM chunks;
```

## Apply a new schema file to an existing database

`schema/*.sql` runs automatically **only on first initialization**
(empty data volume). On a database that already has data, apply the
files you have not yet run by hand, **in order** — they are written
idempotent (`IF NOT EXISTS`), so re-running one is harmless:

```sh
# e.g. after adding schema/0003_chunk_quality.sql to an existing store:
podman compose exec -T db psql -U raguesslighter -d raguesslighter \
  < schema/0003_chunk_quality.sql

# verify the chunk-text constraint is now present:
podman compose exec -T db psql -U raguesslighter -d raguesslighter \
  -tAc "SELECT conname FROM pg_constraint WHERE conname = 'chunks_text_nonempty';"
```

(`0003_chunk_quality.sql` is also *corrective*: if an earlier space-only
`btrim` version of the check is present it is replaced by the
`[^[:space:]]` regex, so the command above converges on the right
constraint either way.)

`0004_halfvec_hnsw.sql` likewise converges: it adds the half-precision
`embedding_hv` mirror (if absent) and (re)creates the HNSW index on it,
so an existing store gains the halfvec index without a re-ingest:

```sh
podman compose exec -T db psql -U raguesslighter -d raguesslighter \
  < schema/0004_halfvec_hnsw.sql
```

## Reset the store

Dropping the tables keeps the database; re-ingest to repopulate:

```sql
DROP TABLE IF EXISTS chunks CASCADE;
DROP TABLE IF EXISTS ownership_events CASCADE;
DROP TABLE IF EXISTS holdings CASCADE;
-- then re-run the schema files:
\i /docker-entrypoint-initdb.d/0001_init.sql
\i /docker-entrypoint-initdb.d/0002_ownership.sql
\i /docker-entrypoint-initdb.d/0003_chunk_quality.sql
```

Or nuke everything including the volume (destructive):

```sh
podman compose down -v && podman compose up -d
```

The schema then re-runs on first init, and the store is empty.

## Change the embedding dimension

This cannot be done with `ALTER` in place. Steps:

1. Stop ingesting.
2. Update `EMBEDDING_DIM` (and `EMBEDDING_MODEL`) in `.env`.
3. Update the `vector(N)` and `halfvec(N)` literals in
   `schema/0001_init.sql` and the `halfvec(N)` literal in
   `schema/0004_halfvec_hnsw.sql` to match.
4. Reset the store (above) so the `chunks` columns are recreated at the
   new dimension.
5. Re-ingest.

Note: pgvector's HNSW caps the full-precision `vector` type at 2000
dims, but the schema indexes the half-precision `embedding_hv` mirror
instead, whose HNSW cap is 4000 dims — so the reference 2560 (and any
width up to 4000) gets a real HNSW index. Only above 4000 does retrieval
fall back to a sequential scan (correct, just slower; fine at typical
store sizes).
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

`0004_halfvec_hnsw.sql` likewise converges: it converts the store to the
halfvec HNSW expression index — dropping a pre-existing `embedding_hv`
mirror column and any non-expression index, then (re)creating the index on the
`embedding::halfvec(N)` cast — so an existing store gains the halfvec index
without a re-ingest:

```sh
podman compose exec -T db psql -U raguesslighter -d raguesslighter \
  < schema/0004_halfvec_hnsw.sql
```

When the index is (re)built on a large store, pgvector builds the HNSW graph
in shared memory. Two separate settings govern this:
- `maintenance_work_mem` (Postgres GUC, default 64 MB) is the build budget.
  If the graph exceeds it, pgvector warns
  `hnsw graph no longer fits into maintenance_work_mem` and the build spills
  to disk -- SLOWER, but the index quality is unchanged.
- `shm_size` (the container `/dev/shm`) must cover the build's shared
  memory. Podman's default 64 MB is too small for the reference 2560-dim
  width, so the `db` service sets `shm_size: 1g` (a too-small /dev/shm fails
  the build with "No space left on device"). Raising `shm_size` does NOT
  raise `maintenance_work_mem`.

To speed up a one-off build of a large store, raise the budget (the 1g
`shm_size` already covers it):

```sh
podman compose exec -T db psql -U raguesslighter -d raguesslighter \
  -c "SET maintenance_work_mem = '1GB'; REINDEX INDEX chunks_embedding_hnsw;"
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
3. Update the `vector(N)` literal in `schema/0001_init.sql` to match (the
   HNSW index is an expression on `embedding::halfvec(N)`, so `N` is read
   from the column at migration time; there is no second literal to update).
4. Reset the store (above) so the `chunks` columns are recreated at the
   new dimension.
5. Re-ingest.

Note: pgvector's HNSW caps the full-precision `vector` type at 2000
dims, but the schema indexes the half-precision EXPRESSION
`embedding::halfvec(N)` instead, whose HNSW cap is 4000 dims — so the
reference 2560 (and any width up to 4000) gets a real HNSW index. Only
above 4000 does retrieval fall back to a sequential scan (correct, just
slower; fine at typical store sizes).

### pgvector version

The filtered-search path sets the `hnsw.iterative_scan` GUC so that a
selective metadata filter does not silently return too few rows. That GUC
requires **pgvector ≥ 0.8.0**. Postgres accepts unknown custom GUCs, so an
older extension would silently ignore the setting (the filtered search would
then return too few rows with no error); to close that gap the application
checks the installed extension version at startup (`Store.create`) and fails
fast if it is missing or older than 0.8.0. The e2e suite repeats the same
check.

Note: the compose file uses the **floating** tag `pgvector/pgvector:pg17`
(always the newest pgvector built for Postgres 17), so the version is not
fixed by the image reference — the startup check is what keeps the
requirement honest. Pin an explicit version tag (e.g.
`pgvector/pgvector:pg17-0.8.0`) if you need reproducible builds.
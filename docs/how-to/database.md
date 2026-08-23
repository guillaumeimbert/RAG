# How to inspect and manage the database

No `psql` client is needed on the host — run one in a throwaway
container on the host network (it reaches the same `localhost:5432`
the app uses):

```sh
podman run --rm --network host pgvector/pgvector:0.8.6-pg17 psql \
  "postgresql://raguesslighter:raguesslighter@127.0.0.1:5432/raguesslighter"
```

(Adjust the credentials if your `compose.yaml` / `.env` differ.) For
one-off queries append `-c "SELECT …"`:

```sh
podman run --rm --network host pgvector/pgvector:0.8.6-pg17 psql \
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

## Schema migrations

The schema is managed by numbered `schema/*.sql` migrations and the
`migrate.exe` tool (see [the CLI reference](../reference/cli.md#migrateexe)).
Migrations are a **deployment step** — they are *not* run automatically by
`Store.create` or the ingest/query binaries. `Store.create` only verifies the
pgvector extension version; the tables must already exist.

**New database.** Bring the schema up to date with `migrate up` (it applies
all the files, in order, each in its own transaction):

```sh
dune exec bin/migrate.exe -- up
```

**Existing database (created before the tracker).** A database that already has
the schema but no `schema_migrations` records (e.g. initialized by an older
version of `compose.yaml`, which used to apply the schema files via
`docker-entrypoint-initdb.d` without leaving records) needs a one-time
`baseline`. It verifies the schema is present (the fingerprint columns must all
exist) and records the current files as applied without re-running them; it
refuses an empty or partially-initialized database. After that, `migrate up`
applies only files added later:

```sh
dune exec bin/migrate.exe -- baseline   # one-time transition (verifies the schema)
dune exec bin/migrate.exe -- status     # verify: all applied, none pending
```

The current `compose.yaml` has no `docker-entrypoint-initdb.d` mount: `migrate up`
is the sole schema authority, so a fresh volume is created empty and brought to
the latest schema by `migrate up` (see **Reset the database**).

**Adding a migration.** Add a new `schema/NNNN_name.sql` file (the next
number). Never edit an applied file — its checksum is recorded in
`schema_migrations` and `migrate up` refuses to continue if a recorded file has
changed (add a new file instead). Then run `migrate up` on each deployment:

```sh
dune exec bin/migrate.exe -- up
```

`migrate status` shows the applied and pending migrations at any time. The
advisory lock serializes concurrent `up` runs, so it is safe to run from a
`Makefile` target, a CI step, or a service entrypoint.

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

Dropping the tables keeps the database; re-ingest to repopulate. The schema
itself is managed by the migration tool (the `schema_migrations` records are
untouched), so if you drop only the **data** (e.g. `TRUNCATE` or delete the
rows) no schema step is needed. If you drop the **tables**, re-apply the
schema by resetting the tracker and re-running `migrate up` (which re-applies
every file, in order):

```sh
podman compose exec -T db psql -U raguesslighter -d raguesslighter \
  -c "DROP TABLE IF EXISTS chunks CASCADE; DROP TABLE IF EXISTS ownership_events CASCADE; DROP TABLE IF EXISTS holdings CASCADE; DROP TABLE IF EXISTS schema_migrations CASCADE;"
dune exec bin/migrate.exe -- up
```

Or nuke everything including the volume (destructive). The compose service
no longer runs the migrations, so a fresh volume is empty; `migrate up` is the
sole schema authority (it applies the files and records them):

```sh
podman compose down -v && podman compose up -d && dune exec bin/migrate.exe -- up
```

(For a database initialized before the migration tracker existed — the older
compose initdb path — run the one-time `migrate baseline` instead, which
verifies the schema is present and records the files without re-running them.)

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

Note: the compose file (and CI) pin a specific tested release,
`pgvector/pgvector:0.8.6-pg17`, rather than the floating `pg17` tag, so
local and CI builds are reproducible. The pin is the newest released patch
(0.8.6), not the 0.8.0 minimum — several releases since 0.8.0 contain
relevant HNSW correctness and maintenance fixes — while the startup check
still enforces the actual feature requirement (≥ 0.8.0) independently.
pgvector's tags are version-first (the pgvector version, then the Postgres
major), so `0.8.6-pg17` is valid while `pg17-0.8.6` is not.
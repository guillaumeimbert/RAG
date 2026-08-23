# Vendored `ppx_rapper`

- Upstream: https://github.com/roddyyaga/ppx_rapper
- Upstream revision: `5b0e62def2d5cc6cbe3dedec1ecb289bee350f9a`
- Imported: 18 July 2026
- Purpose: temporary OCaml 5.5 compatibility bridge while the codebase migrates
  to direct Caqti requests.

Local compatibility changes are intentionally limited to:

1. supplying the `constraint_` pattern required by `ppxlib` 0.38;
2. linking `caqti.classic`, which exposes the classic Caqti request/type API
   after Caqti's library split.

The root `dune` file builds only the PPX, runtime, and Lwt adapter used here.
Upstream examples, tests, Async support, and Eio support remain in the import
for provenance but are excluded from the build graph.

Do not add new `[%rapper]` uses. Remove this directory after the staged direct
Caqti migration reaches zero Rapper expansions.

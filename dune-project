(lang dune 3.20)

(name ragueshlighter)

(generate_opam_files true)

(source
 (github guillaumeimbert/RAG))

(authors "Guillaume Imbert <imbert.guillaume@gmail.com>")

(maintainers "Guillaume Imbert <imbert.guillaume@gmail.com>")

(documentation https://github.com/guillaumeimbert/RAG)

(package
 (name ragueshlighter)
 (synopsis "RAG over SEC EDGAR filings: OCaml + Postgres/pgvector + any OpenAI-compatible inference server")
 (description
  "Ingests SEC EDGAR filings through the official public APIs (daily-index
  sitemaps, per-CIK submissions JSON, static Archives documents), chunks
  the documents and embeds them through an OpenAI-compatible HTTP API
  (vLLM, ninfer, llama.cpp or a cloud provider), stores the vectors in
  PostgreSQL/pgvector and answers questions with grounded retrieval.
  Inference is configured entirely through .env; there are no
  in-process model dependencies.")
 (depends
  (ocaml
   (= 5.5.0))
  (caqti
   (= 2.3.2))
  (caqti-driver-postgresql
   (= 2.3.0))
  (caqti-lwt
   (= 2.3.2))
  cmdliner
  cohttp
  cohttp-lwt
  cohttp-lwt-unix
  lwt_ssl
  http
  lwt
  lwt_ppx
  pg_query
  ppxlib
  re
  uri
  yojson
  zlib
  base
  (alcotest
   :with-test))
 (tags
  (rag edgar sec pgvector)))
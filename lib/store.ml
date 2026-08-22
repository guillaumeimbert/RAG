(** PostgreSQL + pgvector store.

    caqti 2.x with ppx_rapper (lwt variant), the same pattern used in
    alanvi-studio. Vectors are passed as TEXT and cast with [::vector] in
    SQL (no custom type binding needed); similarity is computed in Postgres
    so the HNSW index does the work. *)

type pool = (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t

exception Db of string

let connect (url : string) : pool Lwt.t =
  match Caqti_lwt_unix.connect_pool (Uri.of_string url) with
  | Error e -> Lwt.fail (Db (Caqti_error.show e))
  | Ok p -> Lwt.return p

let close_pool (p : pool) : unit Lwt.t =
  Caqti_lwt_unix.Pool.drain p

(* ------------------------------------------------------------------ *)
(* Queries                                                              *)
(* ------------------------------------------------------------------ *)

(** One row of the chunks table as prepared for insertion. [embedding] is
    the pgvector text form "[0.1, 0.2, ...]". *)
type chunk_row = {
  doc_id : string;
  company : string;
  cik : string;
  ticker : string;
  form : string;
  filed_at : string;
  section : string;
  chunk_index : int;
  text : string;
  embedding : string;
}

(** Maximum chunks per bulk upsert (one round trip per batch). The batch is
    sent as a single JSON array parameter and expanded server-side with
    jsonb_array_elements, so the query stays static and prepared. *)
let upsert_batch = 512

(** Batch upsert: one round trip for the whole batch. Each element of the
    JSON array is [doc_id, company, cik, ticker, form, filed_at, section,
    chunk_index, text, embedding] (all strings; filed_at / chunk_index /
    embedding are cast server-side). *)
let upsert_many_q =
  [%rapper
    execute
    {sql|
      INSERT INTO chunks (
        doc_id, company, cik, ticker, form, filed_at, section,
        chunk_index, text, embedding
      )
      SELECT
        jrow->>0, jrow->>1, jrow->>2, jrow->>3, jrow->>4,
        (jrow->>5)::date, jrow->>6, (jrow->>7)::int, jrow->>8,
        (jrow->>9)::vector
      FROM jsonb_array_elements(%string{rows}::jsonb) AS jrow
      ON CONFLICT (doc_id, chunk_index) DO UPDATE SET
        text      = EXCLUDED.text,
        embedding = EXCLUDED.embedding,
        section   = EXCLUDED.section
    |sql}
    syntax_off]

(** Encode a batch as the JSON array expected by [upsert_many_q]. Yojson
    handles all the escaping (text frequently contains quotes, newlines and
    Unicode). *)
let rows_json (rows : chunk_row list) : string =
  let row_json r =
    `List
      [
        `String r.doc_id;
        `String r.company;
        `String r.cik;
        `String r.ticker;
        `String r.form;
        `String r.filed_at;
        `String r.section;
        `String (string_of_int r.chunk_index);
        `String r.text;
        `String r.embedding;
      ]
  in
  Yojson.Safe.to_string (`List (List.map row_json rows))

(** pgvector text form of a vector: "[0.1, 0.2, ...]". *)
let vector_to_string (v : float list) : string =
  "[" ^ String.concat "," (List.map (fun f -> Printf.sprintf "%.6f" f) v) ^ "]"

(** One retrieval hit, ordered by descending cosine similarity. *)
type hit = {
  id : int;
  doc_id : string;
  company : string;
  cik : string;
  ticker : string;
  form : string;
  filed_at : string;
  section : string;
  text : string;
  similarity : float;
}

let search_q =
  [%rapper
    get_many
    {sql|
      SELECT
        id::int AS @int{id},
        doc_id AS @string{doc_id},
        company AS @string{company},
        cik AS @string{cik},
        COALESCE(ticker, '') AS @string{ticker},
        form AS @string{form},
        filed_at::text AS @string{filed_at},
        COALESCE(section, '') AS @string{section},
        text AS @string{text},
        1 - (embedding <=> %string{q}::vector) AS @float{similarity}
      FROM chunks
      WHERE ('' = %string{cik} OR cik = %string{cik})
        AND ('' = %string{form} OR form = %string{form})
        AND ('' = %string{ticker} OR ticker = %string{ticker})
      ORDER BY embedding <=> %string{q}::vector
      LIMIT %int{top_k}
    |sql}
    record_out syntax_off]

let exists_q =
  [%rapper
    get_one
    {sql|
      SELECT count(*)::int AS @int{count}
      FROM chunks
      WHERE doc_id = %string{doc_id}
    |sql}
    syntax_off]

let stats_q =
  [%rapper
    get_one
    {sql|
      SELECT
        count(*)::int AS @int{chunks},
        count(DISTINCT doc_id)::int AS @int{docs}
      FROM chunks
    |sql}
    syntax_off]

(* ------------------------------------------------------------------ *)
(* Store                                                                *)
(* ------------------------------------------------------------------ *)

type t = {
  pool : pool;
  cfg : Config.t;
}

let create (cfg : Config.t) : t Lwt.t =
  Lwt.bind (connect cfg.Config.database_url) (fun pool -> Lwt.return { pool; cfg })

let close t : unit Lwt.t = close_pool t.pool

let upsert_chunks t (rows : chunk_row list) : unit Lwt.t =
  let rec split acc l =
    if List.length l <= upsert_batch then List.rev (l :: acc)
    else
      let (h, tl) = (List.take upsert_batch l, List.drop upsert_batch l) in
      split (h :: acc) tl
  in
  match split [] rows with
  | [] -> Lwt.return_unit
  | batches ->
    Lwt_list.iter_s
      (fun batch ->
        Lwt.bind
          ( Caqti_lwt_unix.Pool.use
              (fun conn -> upsert_many_q ~rows:(rows_json batch) conn)
              t.pool )
          (function
            | Ok () -> Lwt.return_unit
            | Error e -> Lwt.fail (Db (Caqti_error.show e))))
      batches

(** Vector search with optional metadata filters (empty/None = no filter). *)
let search t ~query ~top_k ?(cik : string option = None) ?(form : string option = None) ?(ticker : string option = None) () :
    hit list Lwt.t =
  Lwt.bind
    ( Caqti_lwt_unix.Pool.use
        (fun conn ->
          search_q
            ~q:query
            ~cik:(Option.value ~default:"" cik)
            ~form:(Option.value ~default:"" form)
            ~ticker:(Option.value ~default:"" ticker)
            ~top_k
            conn)
        t.pool )
    (function
      | Ok hits -> Lwt.return hits
      | Error e -> Lwt.fail (Db (Caqti_error.show e)))

let doc_exists t (doc_id : string) : bool Lwt.t =
  Lwt.bind
    (Caqti_lwt_unix.Pool.use (fun conn -> exists_q ~doc_id conn) t.pool)
    (function
      | Ok n -> Lwt.return (n > 0)
      | Error e -> Lwt.fail (Db (Caqti_error.show e)))

let stats t : (int * int) Lwt.t =
  Lwt.bind (Caqti_lwt_unix.Pool.use (fun conn -> stats_q () conn) t.pool)
    (function
      | Ok (chunks, docs) -> Lwt.return (chunks, docs)
      | Error e -> Lwt.fail (Db (Caqti_error.show e)))
(** PostgreSQL + pgvector store.

    caqti 2.x with ppx_rapper (lwt variant). Vectors are passed as TEXT and
    cast with [::vector] in SQL (no custom type binding needed); similarity is
    computed in Postgres so the HNSW index does the work. *)

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

(** Vector search, two-stage. The inner query retrieves the candidate set
    with the half-precision HNSW index ([ORDER BY embedding_hv <=> q::halfvec
    LIMIT top_k]): pgvector's HNSW caps [vector] at 2000 dims but [halfvec] at
    4000, so at 2560 dims only the halfvec mirror is indexable, and the index
    makes candidate retrieval fast (an Index Scan instead of a sequential
    scan). The inner query nonetheless computes the similarity from the
    FULL-precision [embedding] column, and the outer query reorders the
    candidates by that exact similarity and drops any whose cosine similarity
    falls below [min_similarity], so a nonsense or unrelated query returns
    NOTHING rather than the nearest top_k however bad they are.

    [min_similarity] = 0.0 DISABLES the filter: cosine similarity ranges over
    [-1, 1], so a plain `similarity >= 0.0` would silently drop every
    negative-scoring (anti-parallel) hit. 0.0 is therefore special-cased so the
    default behaviour returns the nearest top_k regardless of sign. Any other
    value (including negative ones) is applied as a literal floor. *)
let search_q =
  [%rapper
    get_many
    {sql|
      SELECT
        id::int AS @int{id},
        doc_id AS @string{doc_id},
        company AS @string{company},
        cik AS @string{cik},
        ticker AS @string{ticker},
        form AS @string{form},
        filed_at AS @string{filed_at},
        section AS @string{section},
        text AS @string{text},
        similarity AS @float{similarity}
      FROM (
        SELECT
          id,
          doc_id,
          company,
          cik,
          COALESCE(ticker, '') AS ticker,
          form,
          filed_at::text AS filed_at,
          COALESCE(section, '') AS section,
          text,
          1 - (embedding <=> %string{q}::vector) AS similarity
        FROM chunks
        WHERE ('' = %string{cik} OR cik = %string{cik})
          AND ('' = %string{form} OR form = %string{form})
          AND ('' = %string{ticker} OR ticker = %string{ticker})
        ORDER BY embedding_hv <=> %string{q}::halfvec
        LIMIT %int{top_k}
      ) ranked
      WHERE (%float{min_similarity} = 0.0
             OR ranked.similarity >= %float{min_similarity})
      ORDER BY ranked.similarity DESC
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

(** A filing may live in any of the three stores (prose chunks and/or
    structured ownership rows); "already ingested" = present in any of
    them. *)
let any_exists_q =
  [%rapper
    get_one
    {sql|
      SELECT
        (SELECT count(*) FROM chunks WHERE doc_id = %string{doc_id})
        + (SELECT count(*) FROM ownership_events WHERE accession = %string{doc_id})
        + (SELECT count(*) FROM holdings WHERE accession = %string{doc_id})
        AS @int{count}
    |sql}
    syntax_off]

let stats_q =
  [%rapper
    get_one
    {sql|
      SELECT
        (SELECT count(*) FROM chunks)::int AS @int{chunks},
        (SELECT count(DISTINCT doc_id) FROM chunks)::int AS @int{docs},
        (SELECT count(*) FROM ownership_events)::int AS @int{ownership_events},
        (SELECT count(*) FROM holdings)::int AS @int{holdings}
    |sql}
    syntax_off]

(* ------------------------------------------------------------------ *)
(* Structured ownership rows (13G / 13D / 13F)                         *)
(* ------------------------------------------------------------------ *)

(** One row of the ownership_events table prepared for a bulk upsert.
    [None] options are encoded as "" and stored as NULL (NULLIF). *)
type own_event_row = {
  accession : string;
  form : string;
  event_date : string;
  (** YYYY-MM-DD *)
  filed_at : string;
  filer_cik : string;
  filer_name : string;
  subject_cik : string;
  subject_name : string;
  subject_cusip : string;
  class_name : string;
  shares : int option;
  percent : float option;
  passive : bool;
  is_amendment : bool;
  index_url : string;
}

(** One row of the holdings table prepared for a bulk upsert. *)
type holding_row = {
  accession : string;
  filer_cik : string;
  filer_name : string;
  period : string;
  (** YYYY-MM-DD (quarter end) *)
  filed_at : string;
  issuer_name : string;
  issuer_cusip : string;
  issuer_cik : string;
  class_name : string;
  value_usd : int option;
  shares : int option;
  prnamt_type : string;
  discretion : string;
  vote_sole : int option;
  vote_shared : int option;
  vote_none : int option;
}

let own_events_json (rows : own_event_row list) : string =
  let row_json (r : own_event_row) =
    `List
      [
        `String r.accession;
        `String r.form;
        `String r.event_date;
        `String r.filed_at;
        `String r.filer_cik;
        `String r.filer_name;
        `String r.subject_cik;
        `String r.subject_name;
        `String r.subject_cusip;
        `String r.class_name;
        `String (Option.map string_of_int r.shares |> Option.value ~default:"");
        `String (Option.map string_of_float r.percent |> Option.value ~default:"");
        `String (Bool.to_string r.passive);
        `String (Bool.to_string r.is_amendment);
        `String r.index_url;
      ]
  in
  Yojson.Safe.to_string (`List (List.map row_json rows))

let upsert_own_events_q =
  [%rapper
    execute
    {sql|
      INSERT INTO ownership_events (
        accession, form, event_date, filed_at, filer_cik, filer_name,
        subject_cik, subject_name, subject_cusip, class,
        shares, percent, passive, is_amendment, index_url
      )
      SELECT
        jrow->>0, jrow->>1, (jrow->>2)::date, (jrow->>3)::date,
        jrow->>4, jrow->>5, jrow->>6, jrow->>7, jrow->>8, jrow->>9,
        NULLIF(jrow->>10, '')::numeric, NULLIF(jrow->>11, '')::numeric,
        (jrow->>12)::bool, (jrow->>13)::bool, jrow->>14
      FROM jsonb_array_elements(%string{rows}::jsonb) AS jrow
      ON CONFLICT (accession, filer_cik, subject_cik, class) DO UPDATE SET
        event_date   = EXCLUDED.event_date,
        filed_at     = EXCLUDED.filed_at,
        filer_name   = EXCLUDED.filer_name,
        subject_name = EXCLUDED.subject_name,
        subject_cusip = EXCLUDED.subject_cusip,
        shares       = EXCLUDED.shares,
        percent      = EXCLUDED.percent,
        passive      = EXCLUDED.passive,
        is_amendment = EXCLUDED.is_amendment,
        index_url    = EXCLUDED.index_url
    |sql}
    syntax_off]

let holdings_json (rows : holding_row list) : string =
  let row_json (r : holding_row) =
    `List
      [
        `String r.accession;
        `String r.filer_cik;
        `String r.filer_name;
        `String r.period;
        `String r.filed_at;
        `String r.issuer_name;
        `String r.issuer_cusip;
        `String r.issuer_cik;
        `String r.class_name;
        `String (Option.map string_of_int r.value_usd |> Option.value ~default:"");
        `String (Option.map string_of_int r.shares |> Option.value ~default:"");
        `String r.prnamt_type;
        `String r.discretion;
        `String (Option.map string_of_int r.vote_sole |> Option.value ~default:"");
        `String (Option.map string_of_int r.vote_shared |> Option.value ~default:"");
        `String (Option.map string_of_int r.vote_none |> Option.value ~default:"");
      ]
  in
  Yojson.Safe.to_string (`List (List.map row_json rows))

let upsert_holdings_q =
  [%rapper
    execute
    {sql|
      INSERT INTO holdings (
        accession, filer_cik, filer_name, period, filed_at,
        issuer_name, issuer_cusip, issuer_cik, class,
        value_usd, shares, prnamt_type, discretion,
        vote_sole, vote_shared, vote_none
      )
      SELECT
        jrow->>0, jrow->>1, jrow->>2, (jrow->>3)::date, (jrow->>4)::date,
        jrow->>5, jrow->>6, jrow->>7, jrow->>8,
        NULLIF(jrow->>9, '')::bigint, NULLIF(jrow->>10, '')::numeric,
        jrow->>11, jrow->>12,
        NULLIF(jrow->>13, '')::numeric, NULLIF(jrow->>14, '')::numeric,
        NULLIF(jrow->>15, '')::numeric
      FROM jsonb_array_elements(%string{rows}::jsonb) AS jrow
      ON CONFLICT (accession, issuer_cusip, class, prnamt_type) DO UPDATE SET
        filer_name  = EXCLUDED.filer_name,
        period      = EXCLUDED.period,
        filed_at    = EXCLUDED.filed_at,
        issuer_name = EXCLUDED.issuer_name,
        issuer_cik  = EXCLUDED.issuer_cik,
        value_usd   = EXCLUDED.value_usd,
        shares      = EXCLUDED.shares,
        discretion  = EXCLUDED.discretion,
        vote_sole   = EXCLUDED.vote_sole,
        vote_shared = EXCLUDED.vote_shared,
        vote_none   = EXCLUDED.vote_none
    |sql}
    syntax_off]

(** Delete every row of one filing (accession) from a single store.
    Connection-scoped so it composes inside [with_transaction]. Used by the
    forced re-ingest path to clear stale rows before rewriting them. *)
let delete_chunks_q =
  [%rapper
    execute
    {sql| DELETE FROM chunks WHERE doc_id = %string{doc_id} |sql}
    syntax_off]

let delete_events_q =
  [%rapper
    execute
    {sql| DELETE FROM ownership_events WHERE accession = %string{doc_id} |sql}
    syntax_off]

let delete_holdings_q =
  [%rapper
    execute
    {sql| DELETE FROM holdings WHERE accession = %string{doc_id} |sql}
    syntax_off]

(** Delete every stored row of one filing (accession) from all three
    stores, on an existing connection, returning a [result] so it composes
    inside [with_transaction]. A filing always writes to a disjoint subset
    of the stores (prose -> chunks, 13G/13D -> chunks+events, 13F ->
    holdings), so deleting all three only touches the stores that filing
    actually wrote. *)
let delete_filing_on (conn : Caqti_lwt.connection) (doc_id : string) :
    (unit, Caqti_error.t) result Lwt.t =
  Lwt.bind (delete_chunks_q ~doc_id conn) (function
    | Ok () ->
      Lwt.bind (delete_events_q ~doc_id conn) (function
        | Ok () ->
          Lwt.bind (delete_holdings_q ~doc_id conn) (function
            | Ok () -> Lwt.return (Ok ())
            | Error _ as r -> Lwt.return r)
        | Error _ as r -> Lwt.return r)
    | Error _ as r -> Lwt.return r)


(* ------------------------------------------------------------------ *)
(* Structured retrieval (SQL, not vectors)                             *)
(* ------------------------------------------------------------------ *)

(** A significant holder of [subject] from the latest 13G/13D event per
    filer, with the previous event's figures for the delta. [shares] /
    [percent] of -1. mean "not stated". *)
type holder = {
  filer_cik : string;
  filer_name : string;
  form : string;
  event_date : string;
  filed_at : string;
  class_name : string;
  shares : float;
  percent : float;
  passive : bool;
  is_amendment : bool;
  index_url : string;
  prev_shares : float;
  prev_percent : float;
}

let holders_q =
  [%rapper
    get_many
    {sql|
      WITH latest AS (
        SELECT
          filer_cik, filer_name, form, event_date, filed_at,
          COALESCE(class, '') AS class_name, shares, percent,
          passive, is_amendment, index_url,
          ROW_NUMBER() OVER (
            PARTITION BY filer_cik ORDER BY event_date DESC, filed_at DESC
          ) AS rn
        FROM ownership_events
        WHERE subject_cik = %string{subject_cik}
      )
      SELECT
        l.filer_cik AS @string{filer_cik},
        COALESCE(l.filer_name, '') AS @string{filer_name},
        l.form AS @string{form},
        l.event_date::text AS @string{event_date},
        l.filed_at::text AS @string{filed_at},
        l.class_name AS @string{class_name},
        COALESCE(l.shares::float8, -1) AS @float{shares},
        COALESCE(l.percent::float8, -1) AS @float{percent},
        l.passive AS @bool{passive},
        l.is_amendment AS @bool{is_amendment},
        COALESCE(l.index_url, '') AS @string{index_url},
        COALESCE(p.shares::float8, -1) AS @float{prev_shares},
        COALESCE(p.percent::float8, -1) AS @float{prev_percent}
      FROM latest l
      LEFT JOIN latest p
        ON p.filer_cik = l.filer_cik AND p.rn = l.rn + 1
      WHERE l.rn = 1
      ORDER BY COALESCE(l.shares, -1) DESC NULLS LAST
      LIMIT %int{limit}
    |sql}
    record_out syntax_off]

(** A 13F position in [issuer] from the latest report of each filer
    (institutional holders of the issuer). Match by CIK when given, else
    by name. *)
type position = {
  filer_cik : string;
  filer_name : string;
  period : string;
  issuer_name : string;
  class_name : string;
  value_usd : float;
  shares : float;
  discretion : string;
  accession : string;
}

let positions_q =
  [%rapper
    get_many
    {sql|
      WITH latest AS (
        SELECT
          filer_cik, filer_name, period, issuer_name, class AS class_name,
          value_usd, shares, discretion, accession,
          ROW_NUMBER() OVER (
            PARTITION BY filer_cik ORDER BY period DESC, filed_at DESC
          ) AS rn
        FROM holdings
        WHERE (%string{issuer_cik} <> '' AND issuer_cik = %string{issuer_cik})
           OR (%string{issuer_cik} = '' AND issuer_name ILIKE %string{issuer_name})
      )
      SELECT
        l.filer_cik AS @string{filer_cik},
        COALESCE(l.filer_name, '') AS @string{filer_name},
        l.period::text AS @string{period},
        l.issuer_name AS @string{issuer_name},
        COALESCE(l.class_name, '') AS @string{class_name},
        COALESCE(l.value_usd::float8, -1) AS @float{value_usd},
        COALESCE(l.shares::float8, -1) AS @float{shares},
        COALESCE(l.discretion, '') AS @string{discretion},
        l.accession AS @string{accession}
      FROM latest l
      WHERE l.rn = 1
      ORDER BY COALESCE(l.value_usd, -1) DESC NULLS LAST
      LIMIT %int{limit}
    |sql}
    record_out syntax_off]

(** The stakes [filer] reported in other companies (13G/13D): the latest
    event per subject. *)
type stake = {
  subject_cik : string;
  subject_name : string;
  form : string;
  event_date : string;
  class_name : string;
  shares : float;
  percent : float;
  passive : bool;
  is_amendment : bool;
  index_url : string;
}

let staked_q =
  [%rapper
    get_many
    {sql|
      WITH latest AS (
        SELECT
          subject_cik, subject_name, form, event_date,
          COALESCE(class, '') AS class_name, shares, percent,
          passive, is_amendment, index_url,
          ROW_NUMBER() OVER (
            PARTITION BY subject_cik ORDER BY event_date DESC, filed_at DESC
          ) AS rn
        FROM ownership_events
        WHERE filer_cik = %string{filer_cik}
      )
      SELECT
        l.subject_cik AS @string{subject_cik},
        COALESCE(l.subject_name, '') AS @string{subject_name},
        l.form AS @string{form},
        l.event_date::text AS @string{event_date},
        l.class_name AS @string{class_name},
        COALESCE(l.shares::float8, -1) AS @float{shares},
        COALESCE(l.percent::float8, -1) AS @float{percent},
        l.passive AS @bool{passive},
        l.is_amendment AS @bool{is_amendment},
        COALESCE(l.index_url, '') AS @string{index_url}
      FROM latest l
      WHERE l.rn = 1
      ORDER BY COALESCE(l.shares, -1) DESC NULLS LAST
      LIMIT %int{limit}
    |sql}
    record_out syntax_off]

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

(** Run [f conn] on one pooled connection wrapped in a single transaction:
    committed when [f] returns [Ok _], rolled back when [f] returns
    [Error _] or raises. Every write [f] performs is atomic with every
    other — either all of them are stored, or none of them are, so an
    interrupted job never leaves a filing half-persisted. *)
let with_tx t (f : (Caqti_lwt.connection -> ('a, Caqti_error.t) result Lwt.t)) : 'a Lwt.t =
  Lwt.catch
    (fun () ->
      Lwt.bind
        ( Caqti_lwt_unix.Pool.use
            (fun conn ->
              let module C = (val conn : Caqti_lwt.CONNECTION) in
              C.with_transaction (fun () -> f conn))
            t.pool )
        (function
          | Ok a -> Lwt.return a
          | Error e -> Lwt.fail (Db (Caqti_error.show e))))
    (function
      | Db s -> Lwt.fail (Db s)
      | e -> Lwt.fail (Db (Printexc.to_string e)))

(** Split [rows] into batches of at most [n]. *)
let split_rows n rows =
  let rec go acc l =
    if List.length l <= n then List.rev (l :: acc)
    else
      let (h, tl) = (List.take n l, List.drop n l) in
      go (h :: acc) tl
  in
  go [] rows

(** [upsert_chunks] on an existing connection: one round trip per batch,
    returning a [result] so it can compose inside [with_transaction]. *)
let upsert_chunks_on (conn : Caqti_lwt.connection) (rows : chunk_row list) :
    (unit, Caqti_error.t) result Lwt.t =
  let rec go = function
    | [] -> Lwt.return (Ok ())
    | batch :: rest ->
      Lwt.bind (upsert_many_q ~rows:(rows_json batch) conn) (function
        | Ok () -> go rest
        | Error _ as r -> Lwt.return r)
  in
  go (split_rows upsert_batch rows)

(** [upsert_chunks] stores chunk rows for one document. With [~force:true]
    the document's existing rows are deleted first, in the *same*
    transaction, so a re-ingest fully replaces what was previously stored
    instead of leaving stale rows behind. [doc_id] (the accession) is passed
    by the caller — it must NOT be derived from [rows]: a forced re-ingest
    that now parses to zero rows must still clear the old rows. *)
let upsert_chunks ?(force = false) t (doc_id : string) (rows : chunk_row list) : unit Lwt.t =
  with_tx t (fun conn ->
    if force && doc_id <> ""
    then
      Lwt.bind (delete_filing_on conn doc_id) (function
        | Ok () -> upsert_chunks_on conn rows
        | Error _ as r -> Lwt.return r)
    else upsert_chunks_on conn rows)

(** Vector search with optional metadata filters (empty/None = no filter). *)
let search t ~query ~top_k ?(cik : string option = None) ?(form : string option = None) ?(ticker : string option = None) ?(min_similarity : float = 0.0) () :
    hit list Lwt.t =
  Lwt.bind
    ( Caqti_lwt_unix.Pool.use
        (fun conn ->
          search_q
            ~q:query
            ~cik:(Option.value ~default:"" cik)
            ~form:(Option.value ~default:"" form)
            ~ticker:(Option.value ~default:"" ticker)
            ~min_similarity
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

(** True when [doc_id] (an accession) is present in any of the three
    stores: prose chunks or structured ownership rows. *)
let filing_exists t (doc_id : string) : bool Lwt.t =
  Lwt.bind
    (Caqti_lwt_unix.Pool.use (fun conn -> any_exists_q ~doc_id conn) t.pool)
    (function
      | Ok n -> Lwt.return (n > 0)
      | Error e -> Lwt.fail (Db (Caqti_error.show e)))

(** Standalone: wipe one filing from all stores (its own transaction). *)
let delete_filing t (doc_id : string) : unit Lwt.t =
  with_tx t (fun conn -> delete_filing_on conn doc_id)

(** Bulk upsert of ownership_events rows (13G/13D), same batching as
    [upsert_chunks]. *)
let upsert_own_events_on (conn : Caqti_lwt.connection) (rows : own_event_row list) :
    (unit, Caqti_error.t) result Lwt.t =
  let rec go = function
    | [] -> Lwt.return (Ok ())
    | batch :: rest ->
      Lwt.bind (upsert_own_events_q ~rows:(own_events_json batch) conn) (function
        | Ok () -> go rest
        | Error _ as r -> Lwt.return r)
  in
  go (split_rows upsert_batch rows)

let upsert_own_events t (rows : own_event_row list) : unit Lwt.t =
  with_tx t (fun conn -> upsert_own_events_on conn rows)

(** Store the ownership events AND the narrative chunks of one 13G/13D
    filing in a single transaction: both are stored, or neither is.
    [~force:true] deletes the filing's existing rows first (keyed on the
    caller-supplied [doc_id], not on the rows, so a zero-row re-ingest still
    clears the old data), in the same transaction, so a re-ingest fully
    replaces them. *)
let upsert_13gd ?(force = false) t (doc_id : string) (events : own_event_row list) (chunks : chunk_row list) : unit Lwt.t =
  with_tx t (fun conn ->
    (* [write] is a thunk: Lwt promises start when they are constructed, so
       the write must not be started before the forced delete finishes, or
       it would run concurrently with the delete on the same connection. *)
    let write () =
      Lwt.bind (upsert_own_events_on conn events) (function
        | Ok () -> upsert_chunks_on conn chunks
        | Error _ as r -> Lwt.return r)
    in
    if force && doc_id <> ""
    then
      Lwt.bind (delete_filing_on conn doc_id) (function
        | Ok () -> write ()
        | Error _ as r -> Lwt.return r)
    else write ())

(** Bulk upsert of holdings rows (13F positions). *)
let upsert_holdings_on (conn : Caqti_lwt.connection) (rows : holding_row list) :
    (unit, Caqti_error.t) result Lwt.t =
  let rec go = function
    | [] -> Lwt.return (Ok ())
    | batch :: rest ->
      Lwt.bind (upsert_holdings_q ~rows:(holdings_json batch) conn) (function
        | Ok () -> go rest
        | Error _ as r -> Lwt.return r)
  in
  go (split_rows upsert_batch rows)

(** Store 13F position rows. [~force:true] deletes the filing's existing
    holdings first (keyed on the caller-supplied [doc_id], so a zero-position
    re-ingest still clears the old rows), in the same transaction, so a
    re-ingest fully replaces them. *)
let upsert_holdings ?(force = false) t (doc_id : string) (rows : holding_row list) : unit Lwt.t =
  with_tx t (fun conn ->
    if force && doc_id <> ""
    then
      Lwt.bind (delete_filing_on conn doc_id) (function
        | Ok () -> upsert_holdings_on conn rows
        | Error _ as r -> Lwt.return r)
    else upsert_holdings_on conn rows)

(* ------------------------------------------------------------------ *)
(* Structured retrieval                                                *)
(* ------------------------------------------------------------------ *)

(** Latest 13G/13D stake per filer on [subject_cik] (10-digit padded). *)
let holders_of t ~subject_cik ~limit : holder list Lwt.t =
  Lwt.bind
    (Caqti_lwt_unix.Pool.use (fun conn -> holders_q ~subject_cik ~limit conn) t.pool)
    (function
      | Ok r -> Lwt.return r
      | Error e -> Lwt.fail (Db (Caqti_error.show e)))

(** Latest 13F position per filer in [issuer_cik] (padded CIK) — or, when
    [issuer_cik] is "", by [issuer_name] (ILIKE). *)
let positions_of t ~issuer_cik ~issuer_name ~limit : position list Lwt.t =
  Lwt.bind
    ( Caqti_lwt_unix.Pool.use
        (fun conn -> positions_q ~issuer_cik ~issuer_name ~limit conn)
        t.pool )
    (function
      | Ok r -> Lwt.return r
      | Error e -> Lwt.fail (Db (Caqti_error.show e)))

(** Latest 13G/13D stake per subject reported by [filer_cik]. *)
let staked_of t ~filer_cik ~limit : stake list Lwt.t =
  Lwt.bind
    (Caqti_lwt_unix.Pool.use (fun conn -> staked_q ~filer_cik ~limit conn) t.pool)
    (function
      | Ok r -> Lwt.return r
      | Error e -> Lwt.fail (Db (Caqti_error.show e)))

type store_stats = {
  chunks : int;
  docs : int;
  ownership_events : int;
  holdings : int;
}

let stats t : store_stats Lwt.t =
  Lwt.bind (Caqti_lwt_unix.Pool.use (fun conn -> stats_q () conn) t.pool)
    (function
      | Ok (chunks, docs, ownership_events, holdings) ->
        Lwt.return { chunks; docs; ownership_events; holdings }
      | Error e -> Lwt.fail (Db (Caqti_error.show e)))
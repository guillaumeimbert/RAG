(** End-to-end test: real pipeline against a scratch Postgres database, with
    the SEC EDGAR and OpenAI endpoints replaced by in-process mock servers
    (see [Mock]).

    Flow:
    1. create a scratch database ([raguesslighter_e2e]) and apply the schema
       (with the embedding dimension rewritten to 8);
    2. [Pipeline.ingest_cik] — submissions JSON -> documents -> chunks ->
       mock embeddings -> store (idempotency checked on the second run);
    3. [Pipeline.ingest_job] from a real EDGAR index page fixture
       (index-page metadata -> primary document -> store);
    4. [Edgar.cik_of_ticker], [Store.search] (with metadata filters) and
       [Openai.chat] against the mocks.

    The test is skipped (exit 0) when Postgres is not reachable. *)

let pg_host = "127.0.0.1"
let pg_port = 5432
let pg_user = "raguesslighter"
let pg_pass = "raguesslighter"
let pg_main_db = "raguesslighter"
let scratch_db = "raguesslighter_e2e"
let embed_dim = 8

(* ------------------------------------------------------------------ *)
(* Raw Postgres (postgresql-ocaml) for DDL only                        *)
(* ------------------------------------------------------------------ *)

let pg_exec dbname sql : unit =
  let c =
    new Postgresql.connection ~host:pg_host ~port:(string_of_int pg_port)
      ~dbname:dbname ~user:pg_user ~password:pg_pass () in
  (try
     let r = c#exec sql in
     (match r#status with
      | Postgresql.Command_ok | Postgresql.Tuples_ok -> c#finish
      | _ -> (c#finish; failwith ("SQL failed: " ^ r#error)))
   with Postgresql.Error e -> (c#finish; failwith (Postgresql.string_of_error e)))

let pg_available () : bool =
  try
    let fd = Unix.(socket PF_INET SOCK_STREAM 0) in
    Unix.connect fd (Unix.ADDR_INET (Unix.inet_addr_of_string pg_host, pg_port));
    Unix.close fd;
    true
  with Unix.Unix_error _ -> false

(* ------------------------------------------------------------------ *)
(* Mock servers                                                        *)
(* ------------------------------------------------------------------ *)

let fixture name = Test_fixtures.read_text (Test_fixtures.fix name)

(* Daily master index served by the EDGAR mock for the ingest_day pre-filter
   test (see step 10). It lists two allow-listed 10-K filings (whose index
   pages the mock serves) plus a Form 4 and a 424B2 (NOT allow-listed, whose
   index pages the mock does not serve — so if they were fetched they would
   404; the pre-filter must avoid fetching them at all). The two unwanted
   filings use fresh CIK/accessions not used anywhere else in the e2e. *)
let master_idx_e2e =
  "Description:           Daily Index of EDGAR Dissemination Feed\n"
  ^ "Last Data Received:    Aug 20, 2026\n"
  ^ "Comments:              webmaster@sec.gov\n"
  ^ "Anonymous FTP:         ftp://ftp.sec.gov/edgar/\n"
  ^ " \n"
  ^ "CIK|Company Name|Form Type|Date Filed|File Name\n"
  ^ "--------------------------------------------------------------------------------\n"
  ^ "1045810|NVIDIA CORP|10-K|20260820|edgar/data/1045810/0001045810-26-000021.txt\n"
  ^ "320193|Apple Inc.|10-K|20260820|edgar/data/320193/0000320193-25-000079.txt\n"
  ^ "9999999|ZETA CORP|4|20260820|edgar/data/9999999/0009999999-26-000900.txt\n"
  ^ "8888888|ETA CORP|424B2|20260820|edgar/data/8888888/0008888888-26-000901.txt"

(** Master index for the ownership-ingestion test (step 11): one SCHEDULE 13G
    and one 13F-HR (both allow-listed; their index pages and data documents
    the mock serves) plus a Form 4 (NOT allow-listed, pre-filtered out). This
    is the live scenario where the 13G was silently skipped (the form regex
    stopped at the space in "SCHEDULE 13G") and the 13F stored zero positions
    (the information table was assumed to be "information_table.xml" instead
    of the index-named "infotable.xml"). *)
let master_idx_e2e_ownership =
  "Description:           Daily Index of EDGAR Dissemination Feed\n"
  ^ "Last Data Received:    Aug 21, 2026\n"
  ^ "Comments:              webmaster@sec.gov\n"
  ^ "Anonymous FTP:         ftp://ftp.sec.gov/edgar/\n"
  ^ " \n"
  ^ "CIK|Company Name|Form Type|Date Filed|File Name\n"
  ^ "--------------------------------------------------------------------------------\n"
  ^ "1045810|NVIDIA CORP|SCHEDULE 13G|20260821|edgar/data/1045810/0001045810-26-000062.txt\n"
  ^ "1045810|NVIDIA CORP|13F-HR|20260821|edgar/data/1045810/0001045810-26-000065.txt\n"
  ^ "1045810|NVIDIA CORP|13F-HR/A|20260821|edgar/data/1045810/0001045810-26-000066.txt\n"
  ^ "7777777|OMEGA CORP|4|20260821|edgar/data/7777777/0007777777-26-001000.txt"

(* Track which index-page paths the EDGAR mock serves, so the e2e can prove
   the master-index pre-filter avoided fetching unwanted index pages. The
   mock handler runs in its own thread, so the list is guarded by a mutex. *)
let edgar_index_requests : string list ref = ref []
let edgar_index_mu = Mutex.create ()
(* All EDGAR archive requests (index pages AND the cover / information-table
   documents). Used to prove that a skipped filing made NO archive fetch at
   all (the discovery pre-filter discards 13F amendments before any download,
   and the ingest guard skips an amendment before its cover / table). *)
let edgar_archive_requests : string list ref = ref []
let edgar_archive_mu = Mutex.create ()
let is_index_path (path : string) =
  let suf = "-index.htm" in
  let n = String.length path in
  let l = String.length suf in
  n >= l && String.sub path (n - l) l = suf
let record_index_request (path : string) =
  Mutex.lock edgar_index_mu;
  edgar_index_requests := path :: !edgar_index_requests;
  Mutex.unlock edgar_index_mu
let record_archive_request (path : string) =
  Mutex.lock edgar_archive_mu;
  edgar_archive_requests := path :: !edgar_archive_requests;
  Mutex.unlock edgar_archive_mu
(* Drain the recorded index-page requests (oldest first) and reset the list,
   so a test inspects exactly the requests made in its own window. *)
let drain_index_requests () =
  Mutex.lock edgar_index_mu;
  let xs = List.rev !edgar_index_requests in
  edgar_index_requests := [];
  Mutex.unlock edgar_index_mu;
  xs
(* Same, for the archive requests. *)
let drain_archive_requests () =
  Mutex.lock edgar_archive_mu;
  let xs = List.rev !edgar_archive_requests in
  edgar_archive_requests := [];
  Mutex.unlock edgar_archive_mu;
  xs

(** Rewrite every vector(N) / halfvec(N) type in the schema to use [dim], so
    the schema (written for the 2560-dim reference model) runs against the
    tiny e2e embedding dimension. Bare numbers in comments or limits
    (e.g. "2560", "<= 4000") are left untouched. *)
let rewrite_dim (dim : int) (sql : string) =
  let dim_s = Printf.sprintf "%d" dim in
  let starts_with (k : string) (i : int) : bool =
    let n = String.length k in
    i + n <= String.length sql && String.sub sql i n = k
  in
  let rec scan (i : int) (buf : Buffer.t) : string =
    if i >= String.length sql then Buffer.contents buf
    else
      let kind =
        if starts_with "halfvec(" i then Some "halfvec("
        else if starts_with "vector(" i then Some "vector("
        else None
      in
      (match kind with
       | None ->
         Buffer.add_char buf sql.[i];
         scan (i + 1) buf
       | Some k ->
         let close_i = String.index_from sql i ')' in
         Buffer.add_string buf k;
         Buffer.add_string buf dim_s;
         Buffer.add_char buf ')';
         scan (close_i + 1) buf)
  in
  scan 0 (Buffer.create (String.length sql + 128))

(** Deterministic mock embedding: one 8-dim vector per input text. *)
let mock_vector (s : string) : float list =
  List.init embed_dim (fun i ->
      float_of_int (String.hash (s ^ "#" ^ string_of_int i) land 0xff) /. 255.0)

(* Parse a pgvector [embedding::text] literal (" [0.1,-0.2,]") into
   floats. *)
let parse_vec (s : string) : float list =
  let t = Stringx.trim s in
  let l = String.length t in
  if l < 2 || String.get t 0 <> '[' || String.get t (l - 1) <> ']'
  then failwith ("parse_vec: not a vector literal: " ^ s)
  else
    let mid = String.sub t 1 (l - 2) in
    let acc = ref [] in
    let cur = ref "" in
    for i = 0 to String.length mid - 1 do
      let c = String.get mid i in
      if c = ','
      then (acc := float_of_string !cur :: !acc; cur := "")
      else cur := !cur ^ String.make 1 c
    done;
    (if !cur <> "" then acc := float_of_string !cur :: !acc; List.rev !acc)

(** [in_str s sub] — substring test ([String.contains] only tests a single
    character). Used to assert on plan/index text. *)
let in_str (s : string) (sub : string) : bool =
  let n = String.length sub in
  if n = 0 then true
  else
    let i = ref 0 and r = ref false in
    while !i + n <= String.length s && not !r do
      if String.sub s !i n = sub then r := true else incr i
    done;
    !r

(** Read query rows as strings (for asserting on stored data). *)
let pg_query dbname sql : string list list =
  let c =
    new Postgresql.connection ~host:pg_host ~port:(string_of_int pg_port)
      ~dbname:dbname ~user:pg_user ~password:pg_pass () in
  (try
     let r = c#exec sql in
     (match r#status with
      | Postgresql.Tuples_ok | Postgresql.Command_ok ->
        let out = r#get_all_lst in
        c#finish;
        out
      | _ -> (c#finish; failwith ("SQL failed: " ^ r#error)))
   with Postgresql.Error e -> (c#finish; failwith (Postgresql.string_of_error e)))

(* Fault injection for the failure-classification tests: when [Some code],
   the corresponding endpoint returns [code] for every request (the client
   then retries to exhaustion and raises [Net.Http_error]). *)
let openai_fault : int option ref = ref None
let edgar_fault : int option ref = ref None

let openai_handler_ok (path : string) (body : string) : Mock.resp option =
  let json s = Some { Mock.code = 200; content_type = "application/json"; body = s } in
  (match path with
  | "/v1/embeddings" ->
    let j = Yojson.Safe.from_string body in
    let texts = Json.list (Json.member "input" j) |> List.map Json.string in
    let data =
      List.mapi
        (fun i t ->
          `Assoc
            [ "object", `String "embedding"
            ; "index", `Int i
            ; "embedding", `List (List.map (fun f -> `Float f) (mock_vector t)) ])
        texts
    in
    (* Return the rows REVERSED (index labels intact): a client that reads
       the rows in arrival order instead of sorting by "index" will assign
       vectors to the wrong texts — the ordering checks below catch it. *)
    json
      (Yojson.Safe.to_string
         (`Assoc
            [ "object", `String "list"
            ; "data", `List (List.rev data)
            ; "model", `String "mock-embed"
            ; "usage", `Assoc [ "prompt_tokens", `Int 0; "total_tokens", `Int 0 ] ]))
  | "/v1/chat/completions" ->
    json
      (Yojson.Safe.to_string
         (`Assoc
            [ "id", `String "mock-1"
            ; "object", `String "chat.completion"
            ; "created", `Int 1
            ; "model", `String "mock-llm"
            ; "choices",
              `List
                [ `Assoc
                    [ "index", `Int 0
                    ; "message", `Assoc [ "role", `String "assistant"
                                       ; "content", `String "mock answer 42" ]
                    ; "finish_reason", `String "stop" ] ]
            ; "usage", `Assoc [ "prompt_tokens", `Int 0; "total_tokens", `Int 0 ] ]))
  | _ -> None)

let openai_handler (path : string) (body : string) : Mock.resp option =
  (match !openai_fault with
  | Some code ->
    Some { Mock.code = code; content_type = "application/json"; body = "fault-injected" }
  | None -> openai_handler_ok path body)


let edgar_handler_ok (path : string) (_body : string) : Mock.resp option =
  let html s = Some { Mock.code = 200; content_type = "text/html"; body = s } in
  let xml s = Some { Mock.code = 200; content_type = "text/xml"; body = s } in
  let doc = fixture "nvda_8k.html" in
  (match path with
  | "/Archives/edgar/data/1045810/0001045810-26-000021-index.htm" ->
    html (fixture "nvda_10k_index.html")
  | "/Archives/edgar/data/320193/0000320193-25-000079-index.htm" ->
    html (fixture "aapl_10k_index.html")
  | "/Archives/edgar/data/1045810/000104581026000021/nvda-20260125.htm" -> html doc
  | "/Archives/edgar/data/320193/000032019325000079/aapl-20250927.htm" -> html doc
  | "/Archives/edgar/data/1045810/000104581026000069/nvda-20260817.htm" -> html doc
  (* ownership filings: raw data XML at the accession root. The index pages
     name the information table "infotable.xml" (not the assumed
     "information_table.xml"); [info_table_url_of] resolves the name from the
     index, so the mock serves it under that real name. *)
  | "/Archives/edgar/data/1045810/0001045810-26-000062-index.htm" ->
    html (fixture "13g_index.html")
  | "/Archives/edgar/data/1045810/0001045810-26-000065-index.htm" ->
    html (fixture "13f_index.html")
  (* 13F amendment (not supported): the discovery pre-filter discards it
     BEFORE the index download, so this route is only a regression guard. If
     the pre-filter regressed, the index would be served (a genuine 13F-HR/A
     page, so the parsed form is the amended one), and the ingest guard would
     still skip it before the cover / information table. *)
  | "/Archives/edgar/data/1045810/0001045810-26-000066-index.htm" ->
    html (fixture "13f_amendment_index.html")
  | "/Archives/edgar/data/1045810/000104581026000066/primary_doc.xml" ->
    xml (fixture "13f_nvda_primary.xml")
  | "/Archives/edgar/data/1045810/000104581026000066/infotable.xml" ->
    xml (fixture "13f_nvda_table.xml")
  | "/Archives/edgar/data/1045810/000104581026000065/primary_doc.xml" ->
    xml (fixture "13f_nvda_primary.xml")
  | "/Archives/edgar/data/1045810/000104581026000065/infotable.xml" ->
    xml (fixture "13f_nvda_table.xml")
  | "/Archives/edgar/data/1045810/000104581026000062/own13g.xml" ->
    xml (fixture "13g_nvda.xml")
  (* malformed 13F information table (7m): a valid cover plus a well-formed
     but schema-invalid table (no <infoTable> rows) -> Failed, not skipped *)
  | "/Archives/edgar/data/1045810/000104581026000094/primary_doc.xml" ->
    xml (fixture "13f_nvda_primary.xml")
  | "/Archives/edgar/data/1045810/000104581026000094/badtable.xml" ->
    xml (fixture "13f_bad_table.xml")
  (* empty 13F information table (7n): a valid cover plus an information
     table downloaded as HTTP-200 with an EMPTY body (a 200 truncation) ->
     Failed, not a benign skip. Only a 404 (no table) is benign. *)
  | "/Archives/edgar/data/1045810/000104581026000098/primary_doc.xml" ->
    xml (fixture "13f_nvda_primary.xml")
  | "/Archives/edgar/data/1045810/000104581026000098/emptitable.xml" -> xml ""
  | "/submissions/CIK0001045810.json" ->
    Some { Mock.code = 200; content_type = "application/json"; body = fixture "nvda_submissions.json" }
  | "/files/company_tickers.json" ->
    Some { Mock.code = 200; content_type = "application/json"; body = fixture "company_tickers.json" }
  (* fault-injection / robustness filings (fresh accessions, not otherwise
     ingested so the jobs are not skipped as already present) *)
  | "/Archives/edgar/data/1045810/000104581026000090/nvda-20260901.htm" -> html doc
  | "/Archives/edgar/data/1045810/000104581026000092/nvda-20260903.htm" -> html doc
  | "/Archives/edgar/data/1045810/000104581026000095/nvda-20260905.htm" -> html doc
  | "/Archives/edgar/data/1045810/000104581026000097/nvda-20260907.htm" -> html ""
  | "/Archives/edgar/data/1045810/000104581026000091/primary_doc.xml" ->
    xml (fixture "13g_nvda.xml")
  | "/Archives/edgar/data/1045810/000104581026000093/primary_doc.xml" ->
    xml (fixture "13g_nvda.xml")
  (* daily master index for the ingest_day pre-filter test (step 10) *)
  | "/2026/QTR3/master.20260820.idx" ->
    Some { Mock.code = 200; content_type = "text/plain"; body = master_idx_e2e }
  (* daily master index for the ownership-ingestion test (step 11) *)
  | "/2026/QTR3/master.20260821.idx" ->
    Some { Mock.code = 200; content_type = "text/plain"; body = master_idx_e2e_ownership }
  | _ -> None)

let edgar_handler (path : string) (_body : string) : Mock.resp option =
  if is_index_path path then record_index_request path;
  if Stringx.starts_with path ~prefix:"/Archives/" then record_archive_request path;
  (match !edgar_fault with
  | Some code ->
    Some { Mock.code = code; content_type = "text/html"; body = "fault-injected" }
  | None -> edgar_handler_ok path _body)


(* ------------------------------------------------------------------ *)
(* Test                                                                *)
(* ------------------------------------------------------------------ *)

let check (name : string) (cond : bool) : unit =
  if cond
  then Printf.printf "  ok  %s\n%!" name
  else (Printf.printf "FAIL  %s\n%!" name; failwith name)

let () =
  if not (pg_available ())
  then
    ( (* Under CI, [RAG_E2E_REQUIRE_PG] is set: a missing database is a hard
         failure (the workflow provides Postgres) rather than a silent skip.
         Locally, the test skips gracefully when Postgres is absent. *)
      (match Sys.getenv_opt "RAG_E2E_REQUIRE_PG" with
       | Some _ ->
         Printf.eprintf
           "e2e: FAIL (Postgres not reachable at 127.0.0.1:5432 but \
            RAG_E2E_REQUIRE_PG is set — the database must be present)\n%!";
         exit 1
       | None ->
         print_endline "e2e: SKIP (Postgres not reachable at 127.0.0.1:5432)";
         exit 0) )
  else
    let edgar_sock = ref None in
    let openai_sock = ref None in
    try
      (* migration e2e: verify the migration tool applies an empty database to
         the latest schema and upgrades an old snapshot. Uses a separate
         database (the migration files use the production embedding dimension,
         so this is not the 8-dim scratch DB used by the ingest/query tests). *)
      let migrate_db = "raguesslighter_e2e_migrate" in
      let migrate_cfg =
        {
          Config.database_url =
            Printf.sprintf "postgresql://%s:%s@%s:%d/%s" pg_user pg_pass pg_host pg_port
              migrate_db;
          openai_base_url = "http://localhost:9/v1";
          openai_api_key = "test";
          openai_embed_base_url = "http://localhost:9/v1";
          openai_embed_api_key = "test";
          llm_model = "mock";
          embedding_model = "mock";
          Config.embedding_dim = embed_dim;
          sec_user_agent = "test@example.com (e2e)";
          sec_browse_edgar_base = "http://localhost:9";
          sec_daily_index_base = "http://localhost:9";
          sec_submissions_base = "http://localhost:9";
          sec_fts_base = "http://localhost:9";
          sec_archives_base = "http://localhost:9";
          sec_company_tickers_url = "http://localhost:9";
          forms = [ "10-K" ];
          chunk_size = 900;
          chunk_overlap = 120;
          top_k = 8;
          min_similarity = 0.0;
        }
      in
      let migrate_tables (db : string) : string =
        (match
           pg_query db
             "SELECT string_agg(tablename, ',' ORDER BY tablename) FROM pg_tables WHERE schemaname='public'"
         with
         | [ [ v ] ] -> v
         | _ -> "")
      in
      (* (a) empty database -> latest schema *)
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ migrate_db ^ ";");
      pg_exec pg_main_db ("CREATE DATABASE " ^ migrate_db ^ ";");
      let up1 = Lwt_main.run (Migration.up migrate_cfg) in
      (match up1 with
      | Error e -> (check "migration up (empty): applied" false; Printf.eprintf "  up: %s\n%!" e; exit 1)
      | Ok _ -> check "migration up (empty): applied" true);
      let tables1 = migrate_tables migrate_db in
      check "migration up (empty): schema_migrations + chunks + holdings + ownership_events"
        (tables1 = "chunks,holdings,ownership_events,schema_migrations");
      let mig_count =
        (match
           pg_query migrate_db "SELECT count(*)::int FROM schema_migrations"
         with
         | [ [ n ] ] -> int_of_string n
         | _ -> -1)
      in
      check "migration up (empty): 6 migrations recorded" (mig_count = 6);
      (* (b) idempotent: a second up is a no-op *)
      let up2 = Lwt_main.run (Migration.up migrate_cfg) in
      (match up2 with
      | Error e -> (check "migration up (idempotent): no error" false; Printf.eprintf "  up: %s\n%!" e; exit 1)
      | Ok _ -> check "migration up (idempotent): no error" true);
      (* (c) old snapshot -> upgraded schema *)
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ migrate_db ^ ";");
      pg_exec pg_main_db ("CREATE DATABASE " ^ migrate_db ^ ";");
      let snap = Lwt_main.run (Migration.snapshot_up_to migrate_cfg 5) in
      (match snap with
      | Error e -> (check "migration snapshot (v<5): applied" false; Printf.eprintf "  snapshot: %s\n%!" e; exit 1)
      | Ok _ -> check "migration snapshot (v<5): applied" true);
      let snap_count =
        (match
           pg_query migrate_db "SELECT count(*)::int FROM schema_migrations"
         with
         | [ [ n ] ] -> int_of_string n
         | _ -> -1)
      in
      check "migration snapshot (v<5): 4 migrations recorded" (snap_count = 4);
      let up3 = Lwt_main.run (Migration.up migrate_cfg) in
      (match up3 with
      | Error e -> (check "migration up (upgrade): applied" false; Printf.eprintf "  up: %s\n%!" e; exit 1)
      | Ok _ -> check "migration up (upgrade): applied" true);
      let tables3 = migrate_tables migrate_db in
      check "migration up (upgrade): full schema present"
        (tables3 = "chunks,holdings,ownership_events,schema_migrations");
      let mig_count3 =
        (match
           pg_query migrate_db "SELECT count(*)::int FROM schema_migrations"
         with
         | [ [ n ] ] -> int_of_string n
         | _ -> -1)
      in
      check "migration up (upgrade): 6 migrations recorded" (mig_count3 = 6);
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ migrate_db ^ ";");

      (* scratch database *)
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ scratch_db ^ ";");
      pg_exec pg_main_db ("CREATE DATABASE " ^ scratch_db ^ ";");
      let schema =
        Test_fixtures.read_text (Test_fixtures.schema_file "0001_init.sql")
        |> rewrite_dim embed_dim
      in
      let schema2 = Test_fixtures.read_text (Test_fixtures.schema_file "0002_ownership.sql") in
      let schema3 = Test_fixtures.read_text (Test_fixtures.schema_file "0003_chunk_quality.sql") in
      let schema4 = Test_fixtures.read_text (Test_fixtures.schema_file "0004_halfvec_hnsw.sql") in
      let schema5 = Test_fixtures.read_text (Test_fixtures.schema_file "0005_position_index.sql") in
      let schema6 = Test_fixtures.read_text (Test_fixtures.schema_file "0006_event_index.sql") in
      pg_exec scratch_db schema;
      pg_exec scratch_db schema2;
      pg_exec scratch_db schema3;
      pg_exec scratch_db schema4;
      pg_exec scratch_db schema5;
      pg_exec scratch_db schema6;
      (* 0a. migration idempotency: re-applying 0005/0006 is a no-op — a second
         execution must not error, and must leave the already-correct keys
         untouched (no lock, no reindex). *)
      pg_exec scratch_db schema5;
      pg_exec scratch_db schema6;
      let holdings_pk_cols =
        (match
           pg_query scratch_db
             ("SELECT array_agg(a.attname::text ORDER BY k.ord) FROM pg_constraint c "
              ^ "CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) "
              ^ "JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum "
              ^ "WHERE c.conrelid = 'holdings'::regclass AND c.contype = 'p'")
         with
         | [ [v] ] -> v
         | _ -> "")
      in
      check "migration 0005 idempotent: holdings PK is (accession, position_index) after a second run"
        (holdings_pk_cols = "{accession,position_index}");
      let own_events_uk_cols =
        (match
           pg_query scratch_db
             ("SELECT array_agg(a.attname::text ORDER BY k.ord) FROM pg_constraint c "
              ^ "CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) "
              ^ "JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum "
              ^ "WHERE c.conname = 'ownership_events_accession_event_index_key'")
         with
         | [ [v] ] -> v
         | _ -> "")
      in
      check "migration 0006 idempotent: ownership_events UK is (accession, event_index) after a second run"
        (own_events_uk_cols = "{accession,event_index}");
      (* 0b. migration 0005 back-fill: insert LEGACY rows (old content PK)
         BEFORE applying 0005, then verify the back-fill assigns a unique
         0-based per-accession ordinal and swaps the key. A separate scratch
         DB is used because the main scratch DB applies 0005 in the schema
         sequence, with no legacy rows to back-fill. *)
      let mig_db = "raguesslighter_e2e_migrate" in
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ mig_db ^ ";");
      pg_exec pg_main_db ("CREATE DATABASE " ^ mig_db ^ ";");
      pg_exec mig_db schema;
      pg_exec mig_db schema2;  (* 0002: holdings with the old content PK *)
      pg_exec mig_db
        ("INSERT INTO holdings (accession, filer_cik, filer_name, period, filed_at, "
         ^ "issuer_name, issuer_cusip, class, value_usd, shares, prnamt_type) VALUES "
         ^ "('8888-0001', '0000000001', 'LEGACY FUND', '2026-03-31', '2026-05-15', 'A CORP', 'CUSIP_A', 'COM', 100, 10, 'SH'), "
         ^ "('8888-0001', '0000000001', 'LEGACY FUND', '2026-03-31', '2026-05-15', 'B CORP', 'CUSIP_B', 'COM', 200, 20, 'SH'), "
         ^ "('8888-0002', '0000000001', 'LEGACY FUND', '2026-03-31', '2026-05-15', 'C CORP', 'CUSIP_C', 'COM', 300, 30, 'SH');");
      pg_exec mig_db schema5;  (* back-fills position_index, swaps the PK *)
      let legacy_ords =
        pg_query mig_db
          "SELECT accession, position_index FROM holdings ORDER BY accession, position_index"
      in
      check "migration 0005 back-fill: legacy rows get a unique 0-based ordinal per accession"
        ( List.length legacy_ords = 3
        && (match legacy_ords with
             | [ [a1; o1]; [a2; o2]; [a3; o3] ] ->
               a1 = "8888-0001" && o1 = "0"
               && a2 = "8888-0001" && o2 = "1"
               && a3 = "8888-0002" && o3 = "0"
             | _ -> false) );
      let mig_pk_cols =
        (match
           pg_query mig_db
             ("SELECT array_agg(a.attname::text ORDER BY k.ord) FROM pg_constraint c "
              ^ "CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) "
              ^ "JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum "
              ^ "WHERE c.conrelid = 'holdings'::regclass AND c.contype = 'p'")
         with
         | [ [v] ] -> v
         | _ -> "")
      in
      check "migration 0005 back-fill: PK is (accession, position_index) after the swap"
        (mig_pk_cols = "{accession,position_index}");
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ mig_db ^ ";");
      Printf.printf "e2e: scratch database %s ready\n%!" scratch_db;

      (* pgvector >= 0.8.0 is required: the filtered-search path relies on the
         hnsw.iterative_scan GUC (introduced in 0.8.0). Older extension
         versions would make the set_config call fail; fail fast with a clear
         message instead. *)
      let pgvec_ver =
        (match pg_query scratch_db "SELECT extversion FROM pg_extension WHERE extname = 'vector'" with
         | [ [v] ] -> v
         | _ -> "0")
      in
      check "pgvector >= 0.8.0 (required for hnsw.iterative_scan)"
        (Store.version_at_least pgvec_ver "0.8.0");
      Printf.printf "e2e: pgvector %s\n%!" pgvec_ver;

      (* Make 429/5xx retry loops (fault injection) finish instantly. *)
      Net.set_backoff_scale 0.0;

      (* mock servers *)
      let (edgar_port, es) = Mock.start edgar_handler in
      edgar_sock := Some es;
      let (openai_port, os) = Mock.start openai_handler in
      openai_sock := Some os;
      let edgar_base = Printf.sprintf "http://127.0.0.1:%d" edgar_port in
      let cfg =
        {
          Config.database_url =
            Printf.sprintf "postgresql://%s:%s@%s:%d/%s" pg_user pg_pass pg_host pg_port
              scratch_db;
          openai_base_url = Printf.sprintf "http://127.0.0.1:%d/v1" openai_port;
          openai_api_key = "test-key";
          openai_embed_base_url = Printf.sprintf "http://127.0.0.1:%d/v1" openai_port;
          openai_embed_api_key = "test-key";
          llm_model = "mock-llm";
          embedding_model = "mock-embed";
          Config.embedding_dim = embed_dim;
          sec_user_agent = "test@example.com (e2e)";
          sec_browse_edgar_base = edgar_base ^ "/cgi-bin/browse-edgar";
          sec_daily_index_base = edgar_base;
          sec_submissions_base = edgar_base ^ "/submissions";
          sec_fts_base = edgar_base ^ "/full-text/search";
          sec_archives_base = edgar_base ^ "/Archives/edgar/data";
          sec_company_tickers_url = edgar_base ^ "/files/company_tickers.json";
          forms = [ "10-K"; "10-Q"; "8-K"; "13F-HR"; "13G" ];
          chunk_size = 900;
          chunk_overlap = 120;
          top_k = 8;
          min_similarity = 0.0;
        }
      in
      let store = Lwt_main.run (Store.create cfg) in

      (* 1. ingest_cik: submissions JSON -> 8-K (vector path) + 13F-HR and
         13G (structured path) *)
      let s1 = Lwt_main.run (Pipeline.ingest_cik store "1045810") in
      Printf.printf "  ingest_cik #1   %s\n%!" (Pipeline.show_stats s1);
      check "ingest_cik: three filings ingested" (s1.Pipeline.docs = 3);
      check "ingest_cik: 8-K chunks + 13G prose stored" (s1.Pipeline.chunks >= 5);
      check "ingest_cik: one ownership event" (s1.Pipeline.events = 1);
      check "ingest_cik: eight 13F positions" (s1.Pipeline.positions = 8);
      check "ingest_cik: Form 4 rows skipped" (s1.Pipeline.skipped = 2);
      check "ingest_cik: nothing failed" (s1.Pipeline.failed = 0);

      (* 2. idempotency: same day again -> nothing new *)
      let s2 = Lwt_main.run (Pipeline.ingest_cik store "1045810") in
      Printf.printf "  ingest_cik #2   %s\n%!" (Pipeline.show_stats s2);
      check "idempotency: no filing re-ingested" (s2.Pipeline.docs = 0);
      check "idempotency: no re-ingested events or positions"
        (s2.Pipeline.events = 0 && s2.Pipeline.positions = 0);
      check "idempotency: nothing skipped differently" (s2.Pipeline.skipped = 5);

      (* 3. ingest_job from a real EDGAR index page (NVDA 10-K) *)
      let filing =
        {
          Edgar.accession = "0001045810-26-000021";
          cik = "1045810";
          index_url =
            edgar_base ^ "/Archives/edgar/data/1045810/0001045810-26-000021-index.htm";
        }
      in
      let fi =
        match Edgar.parse_index filing (fixture "nvda_10k_index.html") with
        | Some fi -> fi
        | None -> failwith "parse_index failed on the NVDA 10-K fixture"
      in
      let r3 = Lwt_main.run (Pipeline.ingest_job store (Pipeline.make_job fi)) in
      let n3 =
        match r3 with
        | Pipeline.Ingested r -> r.chunks
        | Pipeline.Skipped -> failwith "ingest_job: 10-K unexpectedly skipped"
        | Pipeline.Failed why -> failwith ("ingest_job: 10-K failed: " ^ why)
      in
      Printf.printf "  ingest_job 10-K %d chunks\n%!" n3;
      check "ingest_job: 10-K chunks stored" (n3 >= 5);

      (* 3b. embedding ORDER regression: the mock returns its rows in
         reversed order (index labels intact). (a) embed_all over 20 texts
         crosses the 16-per-batch boundary — pairs must come back in input
         order, each text with its own vector; (b) every stored chunk's
         vector must be the embedding of that chunk's own text. *)
      let texts20 = List.init 20 (fun i -> "order-probe-" ^ string_of_int i) in
      let pairs = Lwt_main.run (Pipeline.embed_all cfg texts20) in
      check "embed_all: 20 texts keep input order across batch boundary"
        ( List.length pairs = 20
        && List.for_all2 (fun (t : string) (t2, v) -> t = t2 && v = mock_vector t) texts20 pairs );
      let crows =
        pg_query scratch_db "SELECT text, embedding::text FROM chunks ORDER BY doc_id, chunk_index"
      in
      check "stored vectors align with their chunks (all docs)"
        ( List.length crows > 0
        && List.for_all
             (fun row ->
               (match row with
                | text :: [ embedding ] ->
                  let want = mock_vector text in
                  (match parse_vec embedding with
                   | got -> List.length got = List.length want
                             && List.for_all2 (fun a b -> abs_float (a -. b) <= 1e-6) want got
                   | exception Failure _ -> false)
                | _ -> false))
             crows );

      (* 4. store statistics + retrieval *)
      let st = Lwt_main.run (Store.stats store) in
      Printf.printf "  store stats: %d chunks, %d docs, %d events, %d holdings\n%!"
        st.Store.chunks
        st.Store.docs
        st.Store.ownership_events
        st.Store.holdings;
      check "stats: three documents" (st.Store.docs = 3);
      check "stats: chunk count consistent"
        (st.Store.chunks = s1.Pipeline.chunks + n3);
      check "stats: one ownership event" (st.Store.ownership_events = 1);
      check "stats: eight holdings" (st.Store.holdings = 8);

      let query = Store.vector_to_string (mock_vector "what?") in
      let hits = Lwt_main.run (Store.search store ~query ~top_k:5 ()) in
      check "search: five hits" (List.length hits = 5);
      check "search: hits come from the two documents"
        (List.for_all
           (fun h ->
             h.Store.doc_id = "0001045810-26-000021"
             || h.Store.doc_id = "0001045810-26-000069")
           hits);
      check "search: similarities in range"
        (List.for_all (fun h -> h.Store.similarity <= 1.0) hits);

      (* 4a. recall: widening the inner LIMIT to candidate_k (then reranking the
         candidates with the full-precision embedding) must not lose the true
         top results. Compute Recall@k — the fraction of the EXACT top-k (a
         sequential scan ordered by the full-precision embedding) that appear in
         the indexed search's top-k. A naive inner `LIMIT top_k`, or a candidate
         set too small to contain the exact top-k, would drop some of them and
         score < 1.0. Checking only that the best hit beats the 5th would still
         pass while missing the other four. *)
      let recall_at (k : int) : float =
        let exact_ids =
          List.concat
            (pg_query scratch_db
               (Printf.sprintf
                  "SELECT id::int FROM chunks ORDER BY embedding <=> '%s'::vector ASC LIMIT %d"
                  query
                  k))
        in
        let indexed_ids = List.map (fun (h : Store.hit) -> string_of_int h.Store.id) hits in
        let inter = List.filter (fun i -> List.mem i exact_ids) indexed_ids in
        (float_of_int (List.length inter)) /. (float_of_int k)
      in
      (* Recall@5 against an exact sequential-scan top-5. The ANN candidate set
         (candidate_k = 25 of the 27 scratch chunks, half-precision ordering) is
         approximate, so a single chunk can legitimately fall outside it; require
         at least 4 of the 5 exact rows (a much stronger check than "the best
         hit beats the 5th", which only validated one row). *)
      let r5 = recall_at 5 in
      check "search: Recall@5 >= 0.8 (indexed top-5 covers the exact top-5)"
        (r5 >= 0.8);

      let n_8k =
        (match pg_query scratch_db "SELECT count(*)::int FROM chunks WHERE form = '8-K'" with
         | [ [s] ] -> int_of_string s
         | _ -> 0)
      in
      check "search: 8-K distractors present (non-vacuous filter test)" (n_8k > 0);
      let hk = Lwt_main.run (Store.search store ~query ~top_k:5 ~form:(Some "8-K") ()) in
      check "search: form filter returns every 8-K chunk (capped at top_k)"
        (List.length hk = min 5 n_8k);
      check "search: form filter honoured"
        (List.for_all (fun (h : Store.hit) -> h.Store.form = "8-K") hk);

      (* 4a'. selective vs. broad filters both return the correct count (not
         silently too few). Store.search widens the HNSW search breadth
         (iterative_scan=strict_order + a large ef_search) so a selective
         filter — applied during/after the approximate scan — does not drop
         valid candidates. The 8-K form is the selective case (few matching
         chunks); the 10-K form is the broad case. *)
      let n_10k =
        (match pg_query scratch_db "SELECT count(*)::int FROM chunks WHERE form = '10-K'" with
         | [ [s] ] -> int_of_string s
         | _ -> 0)
      in
      let h10k = Lwt_main.run (Store.search store ~query ~top_k:50 ~form:(Some "10-K") ()) in
      check "search: broad 10-K filter returns the correct count (all 10-K)"
        (n_10k > 0 && List.length h10k = min 50 n_10k
         && List.for_all (fun (h : Store.hit) -> h.Store.form = "10-K") h10k);

      (* 4a''. filtered HNSW iterative scan: on a corpus where the matching rows
         sit FAR from the query in vector-space, a single-pass HNSW scan
         (hnsw.iterative_scan = off) finds none of them, so the filtered query
         returns too few; the strict_order scan (what Store.search sets) keeps
         iterating until enough candidates pass the filter. The search query
         shape is exercised directly with the index FORCED (enable_seqscan off):
         the planner otherwise prefers a sequential scan for filtered queries on
         small tables, which would hide the HNSW behaviour under test. *)
      let filt_db = "raguesslighter_e2e_filtered" in
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ filt_db ^ ";");
      pg_exec pg_main_db ("CREATE DATABASE " ^ filt_db ^ ";");
      pg_exec filt_db "CREATE EXTENSION IF NOT EXISTS vector;";
      (* chunks table WITHOUT the HNSW index: the index is built after the bulk
         insert (a single build pass) rather than one HNSW insert per row. *)
      pg_exec filt_db
        (Printf.sprintf
           "CREATE TABLE chunks (id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_id TEXT NOT NULL, company TEXT NOT NULL, cik TEXT NOT NULL, ticker TEXT, form TEXT NOT NULL, filed_at DATE NOT NULL, section TEXT, chunk_index INT NOT NULL, text TEXT NOT NULL, embedding vector(%d) NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE (doc_id, chunk_index))"
           embed_dim);
      (* 10000 chunks: the 10-K rows lie along the query axis, the 8-K rows are
         ORTHOGONAL to it, so the HNSW scan (ordered by distance to the query)
         reaches the 8-K rows only by iterating past the near 10-K rows. 100 of
         the 8-K rows make the filter selective (1%). *)
      pg_exec filt_db
        ("INSERT INTO chunks (doc_id, company, cik, form, filed_at, chunk_index, text, embedding)\n"
         ^ "SELECT 'd' || g, 'COMP', '1', CASE WHEN g % 100 = 0 THEN '8-K' ELSE '10-K' END,\n"
         ^ "       '2026-01-01', g % 1000, 'x',\n"
         ^ "       CASE WHEN g % 100 = 0\n"
         ^ "         THEN array_to_vector(ARRAY[0.0, 1.0, sin(g)*0.01, cos(g)*0.01, 0,0,0,0], "
         ^ string_of_int embed_dim ^ ", false)\n"
         ^ "         ELSE array_to_vector(ARRAY[1.0, 0.0, sin(g)*0.01, cos(g)*0.01, 0,0,0,0], "
         ^ string_of_int embed_dim ^ ", false) END\n"
         ^ "FROM generate_series(1, 10000) g;");
      pg_exec filt_db
        (Printf.sprintf
           "CREATE INDEX chunks_embedding_hnsw ON chunks USING hnsw ((embedding::halfvec(%d)) halfvec_cosine_ops);"
           embed_dim);
      let n_8k_filt =
        (match pg_query filt_db "SELECT count(*)::int FROM chunks WHERE form = '8-K'" with
         | [ [s] ] -> int_of_string s
         | _ -> 0)
      in
      check "filtered HNSW: 100 8-K rows present (selective filter, non-vacuous)"
        (n_8k_filt = 100);
      (* The exact Store.search query shape: inner LIMIT candidate_k (= 50 for
         top_k = 20), outer LIMIT top_k (= 20). *)
      let qv =
        "[" ^ (String.concat "," (List.init embed_dim (fun i -> if i = 0 then "1" else "0"))) ^ "]"
      in
      let filt_sql =
        "SELECT id::int FROM (SELECT id, 1 - (embedding <=> '" ^ qv ^ "'::vector) AS similarity "
        ^ "FROM chunks WHERE ('' = '' OR cik = '') AND ('' = '8-K' OR form = '8-K') AND ('' = '' OR ticker = '') "
        ^ "ORDER BY (embedding::halfvec(" ^ string_of_int embed_dim ^ ")) <=> '" ^ qv ^ "'::halfvec("
        ^ string_of_int embed_dim ^ ") LIMIT 50) ranked "
        ^ "WHERE 0.0 = 0.0 OR similarity >= 0.0 ORDER BY similarity DESC LIMIT 20"
      in
      (* (a) the planner takes the HNSW expression-index path for the FILTERED
          query (Index Scan + the form filter), not a sequential scan. *)
      let filt_plan =
        String.concat " "
          (List.concat (pg_query filt_db ("SET enable_seqscan = off; EXPLAIN (COSTS OFF) " ^ filt_sql)))
      in
      check "filtered HNSW: the filtered query uses the HNSW index (Index Scan + form filter)"
        (in_str filt_plan "Index Scan" && in_str filt_plan "chunks_embedding_hnsw"
         && in_str filt_plan "form = '8-K'");
      (* (b/c) the effect of hnsw.iterative_scan on the forced HNSW scan, with
         the same ef_search (100) as Store.search. Session-level SETs (no
         transaction) on a single connection, so they apply to the SELECT; the
         connection is closed afterwards, so nothing leaks. *)
      let filt_count mode =
        (match
           pg_query filt_db
             ("SET enable_seqscan = off; SET hnsw.iterative_scan = '" ^ mode ^ "'; "
              ^ "SET hnsw.ef_search = 100; SELECT count(*)::int FROM (" ^ filt_sql ^ ") s;")
         with
         | [ [s] ] -> int_of_string s
         | _ -> 0)
      in
      (* Without iterative scanning a single pass finds no 8-K row (the bug):
          the filtered HNSW scan returns too few. *)
      let count_off = filt_count "off" in
      check "filtered HNSW: without iterative_scan the filtered HNSW scan returns too few"
        (count_off < 20);
      (* With iterative_scan = strict_order (what Store.search sets) the scan
          iterates until enough candidates pass the filter -> the full top-k. *)
      check "filtered HNSW: iterative_scan=strict_order returns the full top-k"
        (filt_count "strict_order" = 20);
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ filt_db ^ ";");

      (* 4b. structured ownership retrieval (SQL path) *)
      let holders = Lwt_main.run (Store.holders_of store ~subject_cik:"0001513845" ~limit:10) in
      check "holders: NVIDIA in Nebius"
        ( List.length holders = 1
        && (match List.hd holders with
             | h ->
               h.Store.filer_cik = "0001045810"
               && h.Store.percent = 9.3
               && h.Store.shares = 22256412.0
               && h.Store.passive = true ) );
      (* issuer CIK was resolved by name against the tickers file *)
      let pos = Lwt_main.run (Store.positions_of store ~issuer_cik:"0001513845" ~issuer_name:"" ~limit:10) in
      check "positions: Nebius held by the NVIDIA 13F"
        ( List.length pos = 1
        && (match List.hd pos with
             | p -> p.Store.filer_cik = "0001045810" && p.Store.issuer_name = "NEBIUS GROUP N.V.") );

      (* 4b-extra. holdings query semantics under the row-ordinal key. A
         single 13F can legitimately list the same (cusip, class, SH) more
         than once (separate lots / managers / put-call splits); the
         retrieval query must (i) sum the lots, (ii) report MIXED when class
         or discretion disagree across the lots, and (iii) select each
         filer's latest accession *before* filtering by issuer — a filer
         that sold the issuer in its newest report is not surfaced as a
         current holder. Rows use private filers (9999999998/9999999999) so
         the fixture's NVIDIA holdings are undisturbed. *)
      let hrow (acc : string) (pi : int) (period : string) (filed_at : string)
        (issuer : string) (cusip : string) (cls : string) (discr : string)
        (value : int option) (shares : int option) : Store.holding_row =
        { accession = acc
        ; position_index = pi
        ; filer_cik = "9999999998"
        ; filer_name = "PRIVATE FUND"
        ; period
        ; filed_at
        ; issuer_name = issuer
        ; issuer_cusip = cusip
        ; issuer_cik = ""
        ; class_name = cls
        ; value_usd = value
        ; shares
        ; prnamt_type = "SH"
        ; put_call = ""
        ; other_manager = ""
        ; discretion = discr
        ; vote_sole = None
        ; vote_shared = None
        ; vote_none = None }
      in
      let hrow9 (acc : string) (pi : int) (period : string) (filed_at : string)
        (issuer : string) (cusip : string) (cls : string) (discr : string)
        (value : int option) (shares : int option) : Store.holding_row =
        { (hrow acc pi period filed_at issuer cusip cls discr value shares)
          with filer_cik = "9999999999" }
      in
      let holdings_count acc =
        (match
           pg_query scratch_db
             ("SELECT count(*)::int FROM holdings WHERE accession = '" ^ acc ^ "';")
         with
         | [ [x] ] -> int_of_string x
         | _ -> -1)
      in
      (* (i) two lots, same (cusip, class, SH), distinct ordinals -> summed *)
      let sum_acc = "9998-0001" in
      Lwt_main.run
        (Store.upsert_holdings store sum_acc
           [ hrow sum_acc 0 "2026-03-31" "2026-05-15" "SUM TEST ISSUER" "000000001" "COM" "SOLE" (Some 100) (Some 10)
           ; hrow sum_acc 1 "2026-03-31" "2026-05-15" "SUM TEST ISSUER" "000000001" "COM" "SOLE" (Some 250) (Some 25) ]);
      let pos_sum =
        Lwt_main.run
          (Store.positions_of store ~issuer_cik:"" ~issuer_name:"SUM TEST ISSUER" ~limit:10)
      in
      check "holdings: two lots with the same (cusip, class, SH) are summed"
        ( List.length pos_sum = 1
        && (match List.hd pos_sum with
             | p -> p.Store.value_usd = 350.0 && p.Store.shares = 35.0
                   && p.Store.class_name = "COM" && p.Store.discretion = "SOLE") );
      (* (iii) the filer's LATEST accession no longer holds SOLD TEST -> the
          older lot is stale and not surfaced as a current position *)
      let sold_acc = "9999-0001" in
      Lwt_main.run
        (Store.upsert_holdings store sold_acc
           [ hrow9 sold_acc 0 "2026-03-31" "2026-05-15" "SOLD TEST ISSUER" "000000003" "COM" "SOLE" (Some 400) (Some 40) ]);
      (* (ii) the same filer's newer accession holds MIXED TEST in two lots
          whose class and discretion disagree -> MIXED *)
      let mix_acc = "9999-0002" in
      Lwt_main.run
        (Store.upsert_holdings store mix_acc
           [ hrow9 mix_acc 0 "2026-06-30" "2026-08-14" "MIXED TEST ISSUER" "000000002" "COM" "SOLE" (Some 200) (Some 20)
           ; hrow9 mix_acc 1 "2026-06-30" "2026-08-14" "MIXED TEST ISSUER" "000000002" "PREFERRED" "SHARED" (Some 300) (Some 30) ]);
      let pos_sold =
        Lwt_main.run
          (Store.positions_of store ~issuer_cik:"" ~issuer_name:"SOLD TEST ISSUER" ~limit:10)
      in
      check "holdings: a filer that sold the issuer in its newest report is not current"
        (List.length pos_sold = 0);
      let pos_mix =
        Lwt_main.run
          (Store.positions_of store ~issuer_cik:"" ~issuer_name:"MIXED TEST ISSUER" ~limit:10)
      in
      check "holdings: class / discretion report MIXED when the lots disagree"
        ( List.length pos_mix = 1
        && (match List.hd pos_mix with
             | p -> p.Store.class_name = "MIXED" && p.Store.discretion = "MIXED"
                   && p.Store.value_usd = 500.0 && p.Store.shares = 50.0) );
      (* (iv) a forced re-ingest of the same accession replaces the rows
          (no duplicate, no "cannot affect row a second time") *)
      Lwt_main.run
        (Store.upsert_holdings ~force:true store mix_acc
           [ hrow9 mix_acc 0 "2026-06-30" "2026-08-14" "MIXED TEST ISSUER" "000000002" "COM" "SOLE" (Some 200) (Some 20)
           ; hrow9 mix_acc 1 "2026-06-30" "2026-08-14" "MIXED TEST ISSUER" "000000002" "PREFERRED" "SHARED" (Some 300) (Some 30) ]);
      check "holdings: a forced re-ingest of the same accession is a replace, not a duplicate"
        (holdings_count mix_acc = 2);

      (* 4c. semantic retrieval relevance: the store must rank by ACTUAL
         cosine similarity, not merely return rows. Insert three chunks with
         hand-crafted ORTHOGONAL unit vectors (bypassing the hash-based mock
         embedding) and assert the exact ranking for each query. Restricted to
         cik "999" so the hash-vector NVDA chunks cannot interfere. *)
      let unit_vec i = List.init embed_dim (fun j -> if j = i then 1.0 else 0.0) in
      let sem_chunk doc text v =
        { Store.doc_id = doc
        ; company = "SEM"
        ; cik = "999"
        ; ticker = ""
        ; form = "10-K"
        ; filed_at = "2026-01-01"
        ; section = "s"
        ; chunk_index = 0
        ; text
        ; embedding = Store.vector_to_string v }
      in
      let () =
        Lwt_main.run
          (Lwt.bind
             (Store.upsert_chunks store "sem-revenue"
                [ sem_chunk "sem-revenue" "Revenue grew 40 percent year over year." (unit_vec 0) ])
             (fun () ->
               Lwt.bind
                 (Store.upsert_chunks store "sem-risk"
                    [ sem_chunk "sem-risk" "Principal risk: supply chain concentration in one region." (unit_vec 1) ])
                 (fun () ->
                   Store.upsert_chunks store "sem-lease"
                     [ sem_chunk "sem-lease" "The operating lease for office 12 was renewed." (unit_vec 2) ])))
      in
      (* Antipodal control: a chunk pointing exactly opposite to the revenue
         vector has cosine similarity -1.0 to it. With the default (disabled)
         threshold the store must still return it, proving MIN_SIMILARITY=0.0
         disables the filter rather than acting as a zero floor that would drop
         every negative-scoring hit. *)
      let () =
        Lwt_main.run
          (Store.upsert_chunks store "sem-anti"
             [ sem_chunk "sem-anti" "Control chunk pointing opposite the revenue vector."
                 (List.init embed_dim (fun j -> if j = 0 then -1.0 else 0.0)) ])
      in
      let rev_hits =
        Lwt_main.run (Store.search store ~query:(Store.vector_to_string (unit_vec 0)) ~top_k:3 ~cik:(Some "999") ())
      in
      check "semantic: a revenue query ranks the revenue chunk first"
        (match rev_hits with
         | h :: _ -> h.Store.doc_id = "sem-revenue" && h.Store.similarity > 0.99
         | [] -> false);
      let risk_hits =
        Lwt_main.run (Store.search store ~query:(Store.vector_to_string (unit_vec 1)) ~top_k:3 ~cik:(Some "999") ())
      in
      check "semantic: a risk query ranks the risk chunk first"
        (match risk_hits with
         | h :: _ -> h.Store.doc_id = "sem-risk" && h.Store.similarity > 0.99
         | [] -> false);

      (* 4d. similarity threshold: a query orthogonal to every stored vector
         has ~0 similarity to everything. With the default threshold it still
         returns the nearest rows; with a minimum-similarity threshold it
         returns NOTHING - the no-results path, so ask does not feed the LLM
         irrelevant material. A genuinely relevant query still passes. *)
      let unrel_q = Store.vector_to_string (unit_vec 3) in
      let unrel_hits =
        Lwt_main.run (Store.search store ~query:unrel_q ~top_k:3 ~cik:(Some "999") ())
      in
      check "semantic: an unrelated query is dissimilar to everything"
        (List.length unrel_hits = 3 && List.for_all (fun h -> h.Store.similarity < 0.01) unrel_hits);
      let none_hits =
        Lwt_main.run
          (Store.search store ~query:unrel_q ~top_k:3 ~cik:(Some "999") ~min_similarity:0.5 ())
      in
      check "threshold: an unrelated query above the threshold returns no results" (none_hits = []);
      let rev_thr =
        Lwt_main.run
          (Store.search store ~query:(Store.vector_to_string (unit_vec 0)) ~top_k:3 ~cik:(Some "999")
             ~min_similarity:0.5 ())
      in
      check "threshold: a relevant query still passes the threshold"
        (match rev_thr with | h :: _ -> h.Store.doc_id = "sem-revenue" | [] -> false);

      (* The antipodal hit (similarity -1.0) is the regression guard for
         "0.0 disables rather than floors at zero": the default threshold keeps
         it; a positive threshold drops it. *)
      let anti_default =
        Lwt_main.run (Store.search store ~query:(Store.vector_to_string (unit_vec 0)) ~top_k:4 ~cik:(Some "999") ())
      in
      check "threshold: a disabled (0.0) threshold keeps a negative-similarity (antipodal) hit"
        (match List.find_opt (fun (h : Store.hit) -> h.Store.doc_id = "sem-anti") anti_default with
         | Some h -> h.Store.similarity < -0.99
         | None -> false);
      let anti_thr =
        Lwt_main.run
          (Store.search store ~query:(Store.vector_to_string (unit_vec 0)) ~top_k:4 ~cik:(Some "999") ~min_similarity:0.5 ())
      in
      check "threshold: a positive threshold drops the negative-similarity (antipodal) hit"
        (List.find_opt (fun (h : Store.hit) -> h.Store.doc_id = "sem-anti") anti_thr = None);

      (* 4e. structured retrieval: latest-event-per-filer selection, previous
         event deltas, multiple filers, and amendment handling. Insert a known
         set of 13G events directly and assert the SQL aggregation. *)
      let ev accession filer date pct sh amend =
        { Store.accession = accession
        ; event_index = 0
        ; form = "13G"
        ; event_date = date
        ; filed_at = date
        ; filer_cik = filer
        ; filer_name = "FILER " ^ filer
        ; subject_cik = "0000000001"
        ; subject_name = "TESTCO"
        ; subject_cusip = ""
        ; class_name = "Class A"
        ; shares = Some sh
        ; percent = Some pct
        ; passive = true
        ; is_amendment = amend
        ; index_url = "" }
      in
      let () =
        Lwt_main.run
          (Store.upsert_own_events store
             [ ev "test-ev-a1" "0000000002" "2026-01-01" 5.0 1000000 false
             ; ev "test-ev-a2" "0000000002" "2026-06-01" 7.0 1500000 false
             ; ev "test-ev-b1" "0000000003" "2026-03-01" 2.0 300000 true ])
      in
      let tco = Lwt_main.run (Store.holders_of store ~subject_cik:"0000000001" ~limit:10) in
      check "structured: two filers returned, ordered by latest stake size" (List.length tco = 2);
      check "structured: latest event per filer wins + previous-event delta"
        (match tco with
         | a :: b :: _ ->
           a.Store.filer_cik = "0000000002"
           && a.Store.percent = 7.0
           && a.Store.shares = 1500000.0
           && a.Store.prev_percent = 5.0
           && a.Store.prev_shares = 1000000.0
           && b.Store.filer_cik = "0000000003"
           && b.Store.percent = 2.0
           && b.Store.prev_percent < 0.
           && b.Store.is_amendment
         | _ -> false);

      (* 4f. halfvec HNSW expression index: at 2560 dims pgvector's HNSW
         cannot index the full-precision vector column (2000-dim cap), so the
         schema keeps that column for exact reranking and indexes the
         half-precision cast (embedding::halfvec(dim)) with an EXPRESSION HNSW
         index (no duplicate column — the cast is stored once). Verify
         (a) no generated mirror column exists, (b) the index is the halfvec
         expression with cosine ops, (c) candidate retrieval uses the index
         (Index Scan when seqscan is disabled), and (d) the 0004 migration
         converts an old-style database (generated mirror column) to the
         expression index. *)
      let is_one (rows : string list list) : bool =
        (match rows with [ ["1"] ] -> true | _ -> false)
      in
      let hv_col_present db =
        is_one (pg_query db
           "SELECT count(*)::int FROM pg_attribute WHERE attrelid = 'chunks'::regclass AND attname = 'embedding_hv'")
      in
      let idx_of db =
        (match pg_query db "SELECT indexdef FROM pg_indexes WHERE indexname = 'chunks_embedding_hnsw'" with
         | [ [d] ] -> d
         | _ -> "")
      in
      check "halfvec: no generated mirror column (expression index instead)"
        (not (hv_col_present scratch_db));
      let idx_def = idx_of scratch_db in
      check "halfvec: HNSW expression index on the halfvec cast (cosine ops)"
        (in_str idx_def "hnsw" && in_str idx_def "::halfvec" && in_str idx_def "halfvec_cosine_ops");
      let qhv = "[" ^ (String.concat "," (List.init embed_dim (fun _ -> "0"))) ^ "]" in
      let expr = Printf.sprintf "(embedding::halfvec(%d))" embed_dim in
      let plan =
        String.concat " "
          (List.concat
             (pg_query scratch_db
                (Printf.sprintf
                   "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM chunks ORDER BY %s <=> '%s'::halfvec LIMIT 5"
                   expr qhv)))
      in
      check "halfvec: candidate retrieval uses the HNSW index (Index Scan)"
        (in_str plan "Index Scan" && in_str plan "chunks_embedding_hnsw");
      (* 0004 migration: an old-style database (full-precision column +
         generated halfvec mirror + the OLD HNSW index built on that mirror
         column) is converted to the expression index: the mirror is dropped
         (taking the old index with it) and the index rebuilt on the cast. *)
      let hv_db = "raguesslighter_e2e_hv" in
      let old_chunks_ddl =
        Printf.sprintf
          "CREATE TABLE chunks (id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_id TEXT NOT NULL, company TEXT NOT NULL, cik TEXT NOT NULL, ticker TEXT, form TEXT NOT NULL, filed_at DATE NOT NULL, section TEXT, chunk_index INT NOT NULL, text TEXT NOT NULL, embedding vector(%d) NOT NULL, embedding_hv halfvec(%d) GENERATED ALWAYS AS (embedding::halfvec) STORED, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE (doc_id, chunk_index))"
          embed_dim
          embed_dim
      in
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ hv_db ^ ";");
      pg_exec pg_main_db ("CREATE DATABASE " ^ hv_db ^ ";");
      pg_exec hv_db "CREATE EXTENSION IF NOT EXISTS vector;";
      pg_exec hv_db old_chunks_ddl;
      (* a few rows + the OLD HNSW index on the generated mirror column (the
         index an old database actually carried). *)
      pg_exec hv_db
        (Printf.sprintf
           "INSERT INTO chunks (doc_id, company, cik, form, filed_at, chunk_index, text, embedding) SELECT 'd' || g, 'C', '1', '10-K', '2026-01-01', g %% 100, 'x', array_to_vector(ARRAY[1,0,0,0,0,0,0,0], %d, false) FROM generate_series(1, 20) g;"
           embed_dim);
      pg_exec hv_db
        (Printf.sprintf
           "CREATE INDEX chunks_embedding_hnsw ON chunks USING hnsw (embedding_hv halfvec_cosine_ops);");
      check "halfvec: old-style DB has the generated mirror before 0004"
        (hv_col_present hv_db);
      let old_idx = idx_of hv_db in
      check "halfvec: old-style DB carries the old HNSW index on the mirror column"
        (in_str old_idx "hnsw" && in_str old_idx "embedding_hv" && not (in_str old_idx "::halfvec"));
      pg_exec hv_db (Test_fixtures.read_text (Test_fixtures.schema_file "0004_halfvec_hnsw.sql"));
      check "halfvec: 0004 drops the generated mirror"
        (not (hv_col_present hv_db));
      let hv_idx = idx_of hv_db in
      check "halfvec: 0004 replaces the old index with the halfvec expression index"
        (in_str hv_idx "hnsw" && in_str hv_idx "::halfvec" && in_str hv_idx "halfvec_cosine_ops"
         && not (in_str hv_idx "embedding_hv"));
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ hv_db ^ ";");

      (* 5. ticker resolution *)
      let nvda = Lwt_main.run (Edgar.cik_of_ticker cfg "NVDA") in
      check "cik_of_ticker: NVDA" (nvda = Some "0001045810");
      let aapl = Lwt_main.run (Edgar.cik_of_ticker cfg "aapl") in
      check "cik_of_ticker: AAPL (case-insensitive)" (aapl = Some "0000320193");
      let zz = Lwt_main.run (Edgar.cik_of_ticker cfg "ZZZZ") in
      check "cik_of_ticker: unknown ticker -> None" (zz = None);

      (* 6. OpenAI client (chat + embed) *)
      let answer =
        Lwt_main.run
          (Openai.chat ~cfg
             [ { Openai.role = `User; content = "Question the filings about revenue growth." } ])
      in
      check "openai.chat: mock answer" (answer = "mock answer 42");
      let vecs = Lwt_main.run (Openai.embed ~cfg [ "alpha"; "beta" ]) in
      check "openai.embed: one vector per input"
        (List.length vecs = 2 && List.for_all (fun v -> List.length v = embed_dim) vecs);

      (* ---------------------------------------------------------------- *)
      (* 7. Failure classification and robustness (fault injection)       *)
      (* ---------------------------------------------------------------- *)
      let mk_index (accession : string) (form : string) (primary_document : string) =
        {
          Edgar.accession;
          cik = "1045810";
          company = "NVIDIA CORP";
          form;
          filed_at = Date.of_string "2026-09-01";
          report_date = None;
          primary_document;
          primary_description = "";
          info_table_document = None;
          (* index_url uses the dashed accession (codebase convention); the
             document path is derived undashed by [Edgar.accession_root]. *)
          index_url =
            edgar_base ^ "/Archives/edgar/data/1045810/" ^ accession ^ "-index.htm";
          ticker = "NVDA";
        }
      in
      let count_where (table : string) (doc_id : string) =
        (match
           pg_query scratch_db
             (Printf.sprintf "SELECT count(*)::int FROM %s WHERE %s = '%s'" table
                (if table = "chunks" then "doc_id" else "accession")
                doc_id)
         with
         | [ [ n ] ] -> int_of_string n
         | _ -> failwith "count_where: unexpected result shape")
      in

      (* 7a. inference 500 -> Failed (not Skipped), nothing stored *)
      openai_fault := Some 500;
      let r500 =
        Lwt_main.run
          (Pipeline.ingest_job_safe store
             (Pipeline.make_job (mk_index "0001045810-26-000090" "8-K" "nvda-20260901.htm")))
      in
      check "inference 500: classified as Failed"
        (match r500 with Pipeline.Failed _ -> true | _ -> false);
      check "inference 500: nothing stored" (count_where "chunks" "0001045810-26-000090" = 0);

      (* 7b. inference 429 (retried to exhaustion) -> Failed *)
      openai_fault := Some 429;
      let r429 =
        Lwt_main.run
          (Pipeline.ingest_job_safe store
             (Pipeline.make_job (mk_index "0001045810-26-000092" "8-K" "nvda-20260903.htm")))
      in
      check "inference 429: classified as Failed"
        (match r429 with Pipeline.Failed _ -> true | _ -> false);
      check "inference 429: nothing stored" (count_where "chunks" "0001045810-26-000092" = 0);
      openai_fault := None;

      (* 7c. EDGAR 404 -> Skipped (the document vanished) *)
      edgar_fault := Some 404;
      let r404 =
        Lwt_main.run
          (Pipeline.ingest_job_safe store
             (Pipeline.make_job (mk_index "0001045810-26-000091" "13G" "primary_doc.xml")))
      in
      check "EDGAR 404: classified as Skipped"
        (match r404 with Pipeline.Skipped -> true | _ -> false);
      check "EDGAR 404: nothing stored"
        (count_where "ownership_events" "0001045810-26-000091" = 0);

      (* 7d. EDGAR 500 (retried to exhaustion) -> Failed, not Skipped *)
      edgar_fault := Some 500;
      let r500e =
        Lwt_main.run
          (Pipeline.ingest_job_safe store
             (Pipeline.make_job (mk_index "0001045810-26-000093" "13G" "primary_doc.xml")))
      in
      check "EDGAR 500: classified as Failed"
        (match r500e with Pipeline.Failed _ -> true | _ -> false);
      check "EDGAR 500: nothing stored"
        (count_where "ownership_events" "0001045810-26-000093" = 0);
      edgar_fault := None;

      (* 7e. empty prose document -> Ingested with zero chunks, no error *)
      let rempty =
        Lwt_main.run
          (Pipeline.ingest_job_safe store
             (Pipeline.make_job (mk_index "0001045810-26-000097" "8-K" "nvda-20260907.htm")))
      in
      check "empty document: Ingested with zero chunks"
        (match rempty with Pipeline.Ingested r -> r.chunks = 0 | _ -> false);
      check "empty document: nothing stored" (count_where "chunks" "0001045810-26-000097" = 0);

      (* 7f. transaction rollback: a successful write followed by a failure
         inside the same transaction leaves nothing behind. *)
      let rrow =
        {
          Store.doc_id = "rollback-test";
          company = "X";
          cik = "1";
          ticker = "";
          form = "8-K";
          filed_at = "2026-09-01";
          section = "s";
          chunk_index = 0;
          text = "rollback probe";
          embedding = Store.vector_to_string (mock_vector "rollback probe");
        }
      in
      let rollback_raised = ref false in
      let () =
        Lwt_main.run
          (Lwt.catch
             (fun () ->
               Store.with_tx store (fun conn ->
                 Lwt.bind (Store.upsert_chunks_on conn [ rrow ]) (function
                   | Ok () -> Lwt.fail (Store.Db "boom after a successful write")
                   | Error _ as e -> Lwt.return e)))
             (function
               | Store.Db _ -> (rollback_raised := true; Lwt.return_unit)
               | e -> (rollback_raised := true; Lwt.fail e)))
      in
      check "rollback: failure surfaces as Store.Db" !rollback_raised;
      check "rollback: the written chunk was not persisted"
        (count_where "chunks" "rollback-test" = 0);

      (* 7g. commit: a clean transaction persists its rows. *)
      let () =
        Lwt_main.run (Store.with_tx store (fun conn -> Store.upsert_chunks_on conn [ rrow ]))
      in
      check "commit: the chunk was persisted" (count_where "chunks" "rollback-test" = 1);
      let () = pg_exec scratch_db "DELETE FROM chunks WHERE doc_id = 'rollback-test';" in

      (* 7h. upsert_13gd atomicity: the second write fails (wrong vector
         dimension), so the events written earlier in the same transaction
         roll back too. *)
      let ev =
        {
          Store.accession = "atom-test";
          event_index = 0;
          form = "13G";
          event_date = "2026-09-01";
          filed_at = "2026-09-01";
          filer_cik = "1045810";
          filer_name = "NVIDIA";
          subject_cik = "1513845";
          subject_name = "NEBIUS";
          subject_cusip = "";
          class_name = "Class A";
          shares = Some 100;
          percent = Some 5.0;
          passive = true;
          is_amendment = false;
          index_url = "";
        }
      in
      let bad_chunk =
        {
          Store.doc_id = "atom-test";
          company = "X";
          cik = "1045810";
          ticker = "";
          form = "13G";
          filed_at = "2026-09-01";
          section = "items";
          chunk_index = 0;
          text = "atomicity probe";
          (* 9 dims <> embed_dim 8 -> the chunks write fails. *)
          embedding = Store.vector_to_string (List.init 9 (fun _ -> 0.1));
        }
      in
      let atom_raised = ref false in
      let () =
        Lwt_main.run
          (Lwt.catch
             (fun () -> Store.upsert_13gd store "atom-test" [ ev ] [ bad_chunk ])
             (function
               | Store.Db _ -> (atom_raised := true; Lwt.return_unit)
               | e -> (atom_raised := true; Lwt.fail e)))
      in
      check "upsert_13gd atomicity: failure surfaces as Store.Db" !atom_raised;
      check "upsert_13gd atomicity: events rolled back"
        (count_where "ownership_events" "atom-test" = 0);
      check "upsert_13gd atomicity: chunks rolled back"
        (count_where "chunks" "atom-test" = 0);

      (* 7i. forced re-ingest: bypasses the already-ingested check and fully
         replaces the stored rows (no duplication). *)
      let force_doc = "0001045810-26-000095" in
      let fjob = Pipeline.make_job (mk_index force_doc "8-K" "nvda-20260905.htm") in
      let r1 = Lwt_main.run (Pipeline.ingest_job_safe store fjob) in
      let n1 = (match r1 with Pipeline.Ingested r -> r.chunks | _ -> -1) in
      check "force: first ingest succeeded" (n1 > 0);
      let r2 = Lwt_main.run (Pipeline.ingest_job_safe store fjob) in
      check "force: plain re-run is Skipped (already ingested)"
        (match r2 with Pipeline.Skipped -> true | _ -> false);
      let r3 = Lwt_main.run (Pipeline.ingest_job_safe ~force:true store fjob) in
      check "force: forced re-ingest is Ingested (bypasses the check)"
        (match r3 with Pipeline.Ingested _ -> true | _ -> false);
      check "force: rows replaced, not duplicated" (count_where "chunks" force_doc = n1);

      (* 7k. forced re-ingest with ZERO new rows still deletes the old rows:
         the replacement is keyed on the accession (doc_id), not on the
         output rows. Regression: deriving the accession from the rows made
         an empty re-ingest skip the delete and leave the old data behind
         (empty prose, or a 13F whose information table disappeared). *)
      let zdoc = "0001045810-26-000099" in
      let zrow =
        {
          Store.doc_id = zdoc;
          company = "X";
          cik = "1";
          ticker = "";
          form = "8-K";
          filed_at = "2026-09-01";
          section = "s";
          chunk_index = 0;
          text = "zero-row probe";
          embedding = Store.vector_to_string (mock_vector "zero-row probe");
        }
      in
      let () = Lwt_main.run (Store.upsert_chunks store zdoc [ zrow ]) in
      check "force zero rows: first write stored" (count_where "chunks" zdoc = 1);
      let () = Lwt_main.run (Store.upsert_chunks ~force:true store zdoc []) in
      check "force zero rows: old rows deleted by a forced empty re-ingest"
        (count_where "chunks" zdoc = 0);

      (* 7l. forced 13G/D re-ingest: the events AND the narrative chunks are
         replaced (not duplicated), and a forced zero-row re-ingest clears
         both. Exercises the upsert_13gd force path directly — the delete
         must complete before the (thunked) write starts on the same
         connection, and the delete is keyed on the accession, not the rows. *)
      let gdoc = "0001045810-26-000098" in
      let gevent () =
        {
          Store.accession = gdoc;
          event_index = 0;
          form = "13G";
          event_date = "2026-09-01";
          filed_at = "2026-09-01";
          filer_cik = "1045810";
          filer_name = "NVIDIA";
          subject_cik = "1513845";
          subject_name = "NEBIUS";
          subject_cusip = "";
          class_name = "Class A";
          shares = Some 100;
          percent = Some 5.0;
          passive = true;
          is_amendment = false;
          index_url = "";
        }
      in
      let gchunk () =
        {
          Store.doc_id = gdoc;
          company = "X";
          cik = "1045810";
          ticker = "";
          form = "13G";
          filed_at = "2026-09-01";
          section = "s";
          chunk_index = 0;
          text = "13gd force probe";
          embedding = Store.vector_to_string (mock_vector "13gd force probe");
        }
      in
      let () = Lwt_main.run (Store.upsert_13gd store gdoc [ gevent () ] [ gchunk () ]) in
      check "force 13gd: first write stored"
        (count_where "ownership_events" gdoc = 1 && count_where "chunks" gdoc = 1);
      let () = Lwt_main.run (Store.upsert_13gd ~force:true store gdoc [ gevent () ] [ gchunk () ]) in
      check "force 13gd: rows replaced, not duplicated"
        (count_where "ownership_events" gdoc = 1 && count_where "chunks" gdoc = 1);
      let () = Lwt_main.run (Store.upsert_13gd ~force:true store gdoc [] []) in
      check "force 13gd: zero-row re-ingest clears events and chunks"
        (count_where "ownership_events" gdoc = 0 && count_where "chunks" gdoc = 0);

      (* 7m. malformed 13F information table: a downloaded NONEMPTY table that
         is well-formed XML but carries no <infoTable> rows (truncated or
         schema-invalid) must be Failed, not a benign "empty holdings" skip.
         The documented 404 case (no table at all) remains a skip; only a
         table that was actually fetched yet parsed to zero rows fails. *)
      let badtable_index =
        {
          Edgar.accession = "0001045810-26-000094";
          cik = "1045810";
          company = "NVIDIA CORP";
          form = "13F-HR";
          filed_at = Date.of_string "2026-09-01";
          report_date = None;
          primary_document = "primary_doc.xml";
          primary_description = "";
          info_table_document = Some "badtable.xml";
          index_url =
            edgar_base ^ "/Archives/edgar/data/1045810/0001045810-26-000094-index.htm";
          ticker = "NVDA";
        }
      in
      let rbad = Lwt_main.run (Pipeline.ingest_job_safe store (Pipeline.make_job badtable_index)) in
      check "malformed 13F table: classified as Failed"
        (match rbad with Pipeline.Failed _ -> true | _ -> false);
      check "malformed 13F table: no holdings stored"
        (count_where "holdings" "0001045810-26-000094" = 0);

      (* 7n. empty 13F information table (HTTP-200, empty body): a table that
         is actually downloaded (a 200 truncation yields an empty body) must
         be Failed, not a benign "empty holdings" skip. The only benign
         "no positions" case is a 404 (no table at all). This guards the
         regression where an empty 200 body was silently treated as a skip. *)
      let emptytable_index =
        {
          Edgar.accession = "0001045810-26-000098";
          cik = "1045810";
          company = "NVIDIA CORP";
          form = "13F-HR";
          filed_at = Date.of_string "2026-09-02";
          report_date = None;
          primary_document = "primary_doc.xml";
          primary_description = "";
          info_table_document = Some "emptitable.xml";
          index_url =
            edgar_base ^ "/Archives/edgar/data/1045810/0001045810-26-000098-index.htm";
          ticker = "NVDA";
        }
      in
      let rempty = Lwt_main.run (Pipeline.ingest_job_safe store (Pipeline.make_job emptytable_index)) in
      check "empty 13F table (HTTP-200): classified as Failed"
        (match rempty with Pipeline.Failed _ -> true | _ -> false);
      check "empty 13F table (HTTP-200): no holdings stored"
        (count_where "holdings" "0001045810-26-000098" = 0);

      (* 8. chunk quality / data integrity: every stored chunk is nonempty,
         within the chunker's size limit, and free of internal section markers
         and leaked HTML markup; the database itself rejects empty/whitespace
         chunk text. Runs after all probe inserts so the whole chunks table
         (real-fixture, semantic and probe chunks) is covered. *)
      let all_chunks =
        (match pg_query scratch_db "SELECT text FROM chunks" with
         | rows -> List.map (fun r -> List.hd r) rows
         | exception Failure _ -> [])
      in
      let max_size = cfg.Config.chunk_size in
      let tag_like = Re.compile (Re.Pcre.re "</?[A-Za-z][^>]*>") in
      let clean t =
        String.trim t <> ""
        && String.length t <= max_size
        && not (String.contains t (Char.chr 31))  (* \x1f section marker *)
        && not (String.contains t (Char.chr 30))  (* \x1e section marker *)
        && Re.all tag_like t = []                 (* no leaked HTML tag *)
      in
      check "chunk quality: every stored chunk is nonempty, size-limited, marker-free, tag-free"
        (List.length all_chunks > 0 && List.for_all clean all_chunks);

      (* the database enforces the nonempty invariant too: a whitespace-only
         chunk is rejected by the CHECK constraint and never stored. The text
         mixes tabs, newlines and spaces on purpose: a btrim (spaces-only)
         check would accept it, so this pins down the POSIX [:space:] fix. *)
      let ws_chunk =
        { Store.doc_id = "sem-ws"; company = "SEM"; cik = "999"; ticker = ""; form = "10-K"
        ; filed_at = "2026-01-01"; section = "s"; chunk_index = 0
        ; text = "\t\n \t"; embedding = Store.vector_to_string (unit_vec 0) }
      in
      let ws_rejected = ref false in
      let () =
        Lwt_main.run
          (Lwt.catch
             (fun () -> Store.upsert_chunks store "sem-ws" [ ws_chunk ])
             (function
               | Store.Db _ -> (ws_rejected := true; Lwt.return_unit)
               | e -> Lwt.fail e))
      in
      check "db: a whitespace-only chunk is rejected (CHECK constraint)" !ws_rejected;
      let ws_stored =
        (match pg_query scratch_db "SELECT count(*)::int FROM chunks WHERE doc_id = 'sem-ws'" with
         | [ [ n ] ] -> int_of_string n | _ -> -1)
      in
      check "db: the rejected chunk was not stored" (ws_stored = 0);

      (* 7j. CLI exit codes (the real ingest binary, as a subprocess): a run
         with failed filings exits non-zero; a clean run and a bad date
         behave correctly. Requires RAG_E2E_INGEST_BIN (CI sets it). *)
      ( match Sys.getenv_opt "RAG_E2E_INGEST_BIN" with
      | Some bin when Sys.file_exists bin ->
        let cli_db = "raguesslighter_e2e_cli" in
        let () =
          pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ cli_db ^ ";");
          pg_exec pg_main_db ("CREATE DATABASE " ^ cli_db ^ ";");
          let schema =
            Test_fixtures.read_text (Test_fixtures.schema_file "0001_init.sql")
            |> rewrite_dim embed_dim
          in
          let schema2 = Test_fixtures.read_text (Test_fixtures.schema_file "0002_ownership.sql") in
          let schema3 = Test_fixtures.read_text (Test_fixtures.schema_file "0003_chunk_quality.sql") in
          let schema4 = Test_fixtures.read_text (Test_fixtures.schema_file "0004_halfvec_hnsw.sql") in
          let schema5 = Test_fixtures.read_text (Test_fixtures.schema_file "0005_position_index.sql") in
          let schema6 = Test_fixtures.read_text (Test_fixtures.schema_file "0006_event_index.sql") in
          pg_exec cli_db schema;
          pg_exec cli_db schema2;
          pg_exec cli_db schema3;
          pg_exec cli_db schema4;
          pg_exec cli_db schema5;
          pg_exec cli_db schema6
        in
        let env_file = Filename.temp_file "rag_e2e_env" ".env" in
        let () =
          let out = open_out env_file in
          output_string out
            ( String.concat "\n"
                [ "DATABASE_URL=postgresql://" ^ pg_user ^ ":" ^ pg_pass ^ "@" ^ pg_host
                  ^ ":" ^ (string_of_int pg_port) ^ "/" ^ cli_db
                ; "OPENAI_BASE_URL=http://127.0.0.1:" ^ (string_of_int openai_port) ^ "/v1"
                ; "OPENAI_API_KEY=test-key"
                ; "OPENAI_EMBED_BASE_URL=http://127.0.0.1:" ^ (string_of_int openai_port)
                  ^ "/v1"
                ; "OPENAI_EMBED_API_KEY=test-key"
                ; "LLM_MODEL=mock-llm"; "EMBEDDING_MODEL=mock-embed"
                ; "EMBEDDING_DIM=" ^ (string_of_int embed_dim)
                ; "SEC_USER_AGENT=test@example.com (e2e)"
                ; "SEC_BROWSE_EDGAR_BASE=" ^ edgar_base ^ "/cgi-bin/browse-edgar"
                ; "SEC_DAILY_INDEX_BASE=" ^ edgar_base
                ; "SEC_SUBMISSIONS_BASE=" ^ edgar_base ^ "/submissions"
                ; "SEC_FTS_BASE=" ^ edgar_base ^ "/full-text/search"
                ; "SEC_ARCHIVES_BASE=" ^ edgar_base ^ "/Archives/edgar/data"
                ; "SEC_COMPANY_TICKERS_URL=" ^ edgar_base ^ "/files/company_tickers.json"
                ; "FORMS=10-K,10-Q,8-K,13F-HR,13G"
                ; "CHUNK_SIZE=900"; "CHUNK_OVERLAP=120"; "TOP_K=8" ] );
          close_out out
        in
        let run_exit_zero (cmd : string) : bool =
          match Unix.system cmd with
          | Unix.WEXITED c -> c = 0
          | _ -> false
        in
        check "CLI: an invalid date exits non-zero"
          (not
             (run_exit_zero
                (Printf.sprintf "%s day NOT_A_DATE --env-file %s >/dev/null 2>&1" bin env_file))
          );
        (* 400 is not retried, so the subprocess fails fast; the 500/429
           retry-to-exhaustion path is covered in-process above. *)
        openai_fault := Some 400;
        check "CLI: a run with failed filings exits non-zero"
          (not
             (run_exit_zero
                (Printf.sprintf "%s ticker --env-file %s NVDA >/dev/null 2>&1" bin env_file))
          );
        openai_fault := None;
        check "CLI: a clean run (stats) exits zero"
          (run_exit_zero (Printf.sprintf "%s stats --env-file %s >/dev/null 2>&1" bin env_file));
        (try Unix.unlink env_file with _ -> ());
        pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ cli_db ^ ";")
      | _ ->
        Printf.printf
          "  ..  CLI exit-code test skipped (set RAG_E2E_INGEST_BIN to the built ingest binary)\n%!" );

      (* 9. migration upgrade: a database created with the OLD space-only
         btrim constraint (and therefore possibly holding tab/newline-only
         junk chunks that the old check admitted) must be upgraded by 0003
         WITHOUT failing. 0003 drops the old constraint, removes the junk
         rows the old one admitted, and installs the stronger regex check.
         The pre-fix migration (no cleanup) would fail here, because
         ADD CONSTRAINT validates the stronger check against every existing
         row. Runs on a dedicated database so it cannot disturb the main
         scratch store. *)
      let migrate_db = "raguesslighter_e2e_migrate" in
      let junk_vec = Store.vector_to_string (List.init embed_dim (fun _ -> 0.0)) in
      let migrate_ok = ref true in
      let now_rejected = ref false in
      let junk_count () =
        (match pg_query migrate_db "SELECT count(*)::int FROM chunks WHERE NOT (text ~ '[^[:space:]]')" with
         | [ [ n ] ] -> int_of_string n | _ -> -1)
      in
      ( pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ migrate_db ^ ";");
        pg_exec pg_main_db ("CREATE DATABASE " ^ migrate_db ^ ";");
        pg_exec migrate_db schema;  (* 0001, dimension rewritten to 8 *)
        (* install the OLD (space-only) constraint, as an earlier 0003 would have *)
        pg_exec migrate_db
          "ALTER TABLE chunks ADD CONSTRAINT chunks_text_nonempty CHECK (btrim(text) <> '');";
        (* the old space-only check ADMITS a tab/newline-only chunk: btrim strips
           spaces only, so the tab/newline survive and btrim(text) <> '' holds. *)
        pg_exec migrate_db
          ("INSERT INTO chunks (doc_id, company, cik, form, filed_at, chunk_index, text, embedding) "
           ^ "VALUES ('migrate-junk', 'X', '999', '10-K', '2026-01-01', 0, E'\\t\\n', '" ^ junk_vec ^ "'::vector)");
        check "migrate: the old (space-only) constraint admitted a tab/newline-only chunk" (junk_count () = 1);
        (* apply the NEW 0003: it must succeed on this old database. *)
        (try pg_exec migrate_db schema3 with _ -> migrate_ok := false);
        check "migrate: 0003 upgrades an old-constraint database without failing" !migrate_ok;
        check "migrate: the whitespace-only junk chunk was removed" (junk_count () = 0);
        (* the regex constraint is now active: a fresh whitespace-only insert is rejected. *)
        (try
           pg_exec migrate_db
             ("INSERT INTO chunks (doc_id, company, cik, form, filed_at, chunk_index, text, embedding) "
              ^ "VALUES ('migrate-junk2', 'X', '999', '10-K', '2026-01-01', 1, E'\\t\\n  \\t', '" ^ junk_vec ^ "'::vector)");
         with _ -> now_rejected := true);
        check "migrate: after upgrade a whitespace-only chunk is rejected (regex constraint active)"
          !now_rejected;
        pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ migrate_db ^ ";") );

      (* 10. master-index discovery pre-filter: ingest_day fetches the daily
         master index ONCE and pre-filters rows by FORMS, so each accession's
         index page is fetched only for allow-listed filings. The mock lists
         two 10-K filings (allow-listed; their index pages are served) plus a
         Form 4 and a 424B2 (NOT allow-listed; their index pages are not
         served, so if fetched they would 404 — the pre-filter must avoid
         fetching them). Index-page requests are tracked so the test can prove
         the two unwanted pages were never requested. Runs on a dedicated
         database so the main scratch store is undisturbed. *)
      let master_db = "raguesslighter_e2e_master" in
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ master_db ^ ";");
      pg_exec pg_main_db ("CREATE DATABASE " ^ master_db ^ ";");
      pg_exec master_db schema;
      pg_exec master_db schema2;
      pg_exec master_db schema3;
      let mcfg =
        {
          cfg
          with Config.database_url =
            Printf.sprintf "postgresql://%s:%s@%s:%d/%s" pg_user pg_pass pg_host pg_port
              master_db;
        }
      in
      let mstore = Lwt_main.run (Store.create mcfg) in
      ignore (drain_index_requests ());  (* clear any prior windows *)
      let sm = Lwt_main.run (Pipeline.ingest_day mstore (Date.of_string "2026-08-20")) in
      Printf.printf "  ingest_day (master)   %s\n%!" (Pipeline.show_stats sm);
      check "ingest_day (master): two allow-listed 10-K filings ingested" (sm.Pipeline.docs = 2);
      check "ingest_day (master): nothing failed" (sm.Pipeline.failed = 0);
      let idx_reqs = drain_index_requests () in
      let req p = List.mem p idx_reqs in
      check "ingest_day (master): NVDA 10-K index page fetched"
        (req "/Archives/edgar/data/1045810/0001045810-26-000021-index.htm");
      check "ingest_day (master): AAPL 10-K index page fetched"
        (req "/Archives/edgar/data/320193/0000320193-25-000079-index.htm");
      (* the pre-filter must have avoided fetching the non-allow-listed
         filings' index pages (Form 4 and 424B2) *)
      check "ingest_day (master): Form 4 index page NOT fetched (pre-filtered)"
        (not (req "/Archives/edgar/data/9999999/0009999999-26-000900-index.htm"));
      check "ingest_day (master): 424B2 index page NOT fetched (pre-filtered)"
        (not (req "/Archives/edgar/data/8888888/0008888888-26-000901-index.htm"));
      Lwt_main.run (Store.close mstore);
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ master_db ^ ";");

      (* 11. ownership ingestion through the master path: a SCHEDULE 13G and a
         13F-HR are allow-listed and their index pages fetched; the 13G now
         ingests its event (the form regex no longer stops at the space in
         "SCHEDULE 13G", and the data is the index's .xml, not the .html twin)
         and the 13F now stores its positions (the information table is
         resolved from the index-named "infotable.xml", not the assumed
         "information_table.xml"). A Form 4 is pre-filtered out. Runs on a
         dedicated database so the main scratch store is undisturbed. *)
      let own_db = "raguesslighter_e2e_ownership" in
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ own_db ^ ";");
      pg_exec pg_main_db ("CREATE DATABASE " ^ own_db ^ ";");
      pg_exec own_db schema;
      pg_exec own_db schema2;
      pg_exec own_db schema3;
      pg_exec own_db schema5;
      pg_exec own_db schema6;
      let ocfg =
        {
          cfg
          with Config.database_url =
            Printf.sprintf "postgresql://%s:%s@%s:%d/%s" pg_user pg_pass pg_host pg_port
              own_db;
              (* Explicitly allow-list the 13F amendment: the discovery
                 pre-filter must STILL discard it (13F amendments are
                 unsupported regardless of FORMS). This is exactly what the
                 "no archive request" assertion below checks — without this
                 the pre-filter's FORMS branch would drop it and the test
                 would not prove the amendment-specific branch fires. *)
          Config.forms = [ "10-K"; "10-Q"; "8-K"; "13F-HR"; "13F-HR/A"; "13G" ];
        }
      in
      let ostore = Lwt_main.run (Store.create ocfg) in
      ignore (drain_index_requests ());  (* clear any prior windows *)
      ignore (drain_archive_requests ());
      let so = Lwt_main.run (Pipeline.ingest_day ostore (Date.of_string "2026-08-21")) in
      Printf.printf "  ingest_day (ownership) %s\n%!" (Pipeline.show_stats so);
      check "ingest_day (ownership): both 13G and 13F ingested" (so.Pipeline.docs = 2);
      check "ingest_day (ownership): nothing failed" (so.Pipeline.failed = 0);
      check "ingest_day (ownership): 13G event stored (space-form no longer skipped)"
        (so.Pipeline.events = 1);
      check "ingest_day (ownership): 13F positions stored (index-named info table resolved)"
        (so.Pipeline.positions = 8);
      let own_reqs = drain_index_requests () in
      let own_arch = drain_archive_requests () in
      let oreq p = List.mem p own_reqs in
      check "ingest_day (ownership): 13G index page fetched"
        (oreq "/Archives/edgar/data/1045810/0001045810-26-000062-index.htm");
      check "ingest_day (ownership): 13F index page fetched"
        (oreq "/Archives/edgar/data/1045810/0001045810-26-000065-index.htm");
      (* 13F amendment (13F-HR/A): the discovery pre-filter discards it
         BEFORE any download, so NO archive request (index, cover, or
         information table) is made for its accession. It is allow-listed in
         the ocfg above precisely to prove the pre-filter's amendment branch
         fires (not just its FORMS branch). The index route serves a genuine
         13F-HR/A page, so if the pre-filter regressed the index would be
         fetched (parsed form = 13F-HR/A) and the ingest guard would have to
         skip it. *)
      let amend_paths =
        [
          "/Archives/edgar/data/1045810/0001045810-26-000066-index.htm";
          "/Archives/edgar/data/1045810/000104581026000066/primary_doc.xml";
          "/Archives/edgar/data/1045810/000104581026000066/infotable.xml";
        ]
      in
      check "ingest_day (ownership): 13F amendment makes no archive request (pre-filtered before download)"
        (List.for_all (fun p -> not (List.mem p own_arch)) amend_paths);
      check "ingest_day (ownership): 13F amendment index page NOT fetched (pre-filtered)"
        (not (oreq "/Archives/edgar/data/1045810/0001045810-26-000066-index.htm"));
      let amendment_holdings =
        (match
           pg_query own_db
             "SELECT count(*)::int FROM holdings WHERE accession = '0001045810-26-000066'"
         with
         | [ [ n ] ] -> int_of_string n
         | _ -> -1)
      in
      check "ingest_day (ownership): 13F amendment is skipped (no rows stored)"
        (amendment_holdings = 0);
      check "ingest_day (ownership): Form 4 index page NOT fetched (pre-filtered)"
        (not (oreq "/Archives/edgar/data/7777777/0007777777-26-001000-index.htm"));
      Lwt_main.run (Store.close ostore);
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ own_db ^ ";");

      (* cleanup *)
      Lwt_main.run (Store.close store);
      Option.iter (fun s -> s ()) !edgar_sock;
      Option.iter (fun s -> s ()) !openai_sock;
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ scratch_db ^ ";");
      print_endline "e2e: PASS";
      exit 0
    with e ->
      (Option.iter (fun s -> s ()) !edgar_sock; Option.iter (fun s -> s ()) !openai_sock);
      (* leave the scratch database in place on failure for inspection;
         the next run drops it again *)
      Printf.eprintf "e2e: FAIL %s\n%!" (Printexc.to_string e);
      exit 1
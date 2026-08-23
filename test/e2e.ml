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

(** [find_sub s sub] = index of the first occurrence of [sub] in [s]. *)
let find_sub (s : string) (sub : string) : int option =
  let n = String.length sub in
  if n = 0 || String.length s < n then None
  else
    let i = ref 0 in
    let r = ref None in
    while !i + n <= String.length s && Option.is_none !r do
      if String.sub s !i n = sub then r := Some !i else incr i
    done;
    !r

(** Rewrite the single vector(N) column declaration in the schema to vector(dim). *)
let rewrite_dim (dim : int) (sql : string) =
  let start_i =
    (match find_sub sql "vector(" with
     | Some i -> i
     | None -> failwith "vector( not found in schema")
  in
  let close_i = String.index_from sql start_i ')' in
  String.sub sql 0 start_i
  ^ Printf.sprintf "vector(%d)" dim
  ^ String.sub sql (close_i + 1) (String.length sql - close_i - 1)

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
  (* ownership filings: raw data XML at the accession root *)
  | "/Archives/edgar/data/1045810/000104581026000065/primary_doc.xml" ->
    xml (fixture "13f_nvda_primary.xml")
  | "/Archives/edgar/data/1045810/000104581026000065/information_table.xml" ->
    xml (fixture "13f_nvda_table.xml")
  | "/Archives/edgar/data/1045810/000104581026000062/primary_doc.xml" ->
    xml (fixture "13g_nvda.xml")
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
  | _ -> None)

let edgar_handler (path : string) (_body : string) : Mock.resp option =
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
      (* scratch database *)
      pg_exec pg_main_db ("DROP DATABASE IF EXISTS " ^ scratch_db ^ ";");
      pg_exec pg_main_db ("CREATE DATABASE " ^ scratch_db ^ ";");
      let schema =
        Test_fixtures.read_text (Test_fixtures.schema_file "0001_init.sql")
        |> rewrite_dim embed_dim
      in
      let schema2 = Test_fixtures.read_text (Test_fixtures.schema_file "0002_ownership.sql") in
      let schema3 = Test_fixtures.read_text (Test_fixtures.schema_file "0003_chunk_quality.sql") in
      pg_exec scratch_db schema;
      pg_exec scratch_db schema2;
      pg_exec scratch_db schema3;
      Printf.printf "e2e: scratch database %s ready\n%!" scratch_db;

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

      let hk = Lwt_main.run (Store.search store ~query ~top_k:5 ~form:(Some "8-K") ()) in
      check "search: form filter honoured"
        (List.for_all (fun (h : Store.hit) -> h.Store.form = "8-K") hk);

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
          pg_exec cli_db schema;
          pg_exec cli_db schema2;
          pg_exec cli_db schema3
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
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

let openai_handler (path : string) (body : string) : Mock.resp option =
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

let edgar_handler (path : string) (_body : string) : Mock.resp option =
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
  | _ -> None)

(* ------------------------------------------------------------------ *)
(* Test                                                                *)
(* ------------------------------------------------------------------ *)

let check (name : string) (cond : bool) : unit =
  if cond
  then Printf.printf "  ok  %s\n%!" name
  else (Printf.printf "FAIL  %s\n%!" name; failwith name)

let () =
  if not (pg_available ())
  then (
    print_endline "e2e: SKIP (Postgres not reachable at 127.0.0.1:5432)";
    exit 0)
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
      pg_exec scratch_db schema;
      pg_exec scratch_db schema2;
      Printf.printf "e2e: scratch database %s ready\n%!" scratch_db;

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
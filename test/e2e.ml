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
let pg_user = "ragueshlighter"
let pg_pass = "ragueshlighter"
let pg_main_db = "ragueshlighter"
let scratch_db = "ragueshlighter_e2e"
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

(** Deterministic mock embedding: one 8-dim vector per input text. *)
let mock_vector (s : string) : float list =
  List.init embed_dim (fun i ->
      float_of_int (String.hash (s ^ "#" ^ string_of_int i) land 0xff) /. 255.0)

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
    json
      (Yojson.Safe.to_string
         (`Assoc
            [ "object", `String "list"
            ; "data", `List data
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
  let doc = fixture "nvda_8k.html" in
  (match path with
  | "/Archives/edgar/data/1045810/0001045810-26-000021-index.htm" ->
    html (fixture "nvda_10k_index.html")
  | "/Archives/edgar/data/320193/0000320193-25-000079-index.htm" ->
    html (fixture "aapl_10k_index.html")
  | "/Archives/edgar/data/1045810/000104581026000021/nvda-20260125.htm" -> html doc
  | "/Archives/edgar/data/320193/000032019325000079/aapl-20250927.htm" -> html doc
  | "/Archives/edgar/data/1045810/000104581026000069/nvda-20260817.htm" -> html doc
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
        |> Stringx.replace ~sub:"vector(768)" ~by:(Printf.sprintf "vector(%d)" embed_dim)
      in
      pg_exec scratch_db schema;
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
          forms = [ "10-K"; "10-Q"; "8-K" ];
          chunk_size = 900;
          chunk_overlap = 120;
          top_k = 8;
        }
      in
      let store = Lwt_main.run (Store.create cfg) in

      (* 1. ingest_cik: submissions JSON -> 8-K document -> chunks -> store *)
      let s1 = Lwt_main.run (Pipeline.ingest_cik store "1045810") in
      Printf.printf "  ingest_cik #1   %s\n%!" (Pipeline.show_stats s1);
      check "ingest_cik: one document ingested" (s1.Pipeline.docs = 1);
      check "ingest_cik: chunks stored" (s1.Pipeline.chunks >= 5);
      check "ingest_cik: other forms skipped" (s1.Pipeline.skipped = 4);

      (* 2. idempotency: same day again -> nothing new *)
      let s2 = Lwt_main.run (Pipeline.ingest_cik store "1045810") in
      Printf.printf "  ingest_cik #2   %s\n%!" (Pipeline.show_stats s2);
      check "idempotency: no document re-ingested" (s2.Pipeline.docs = 0);
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
      let n3 = Lwt_main.run (Pipeline.ingest_job store (Pipeline.make_job fi)) in
      Printf.printf "  ingest_job 10-K %d chunks\n%!" n3;
      check "ingest_job: 10-K chunks stored" (n3 >= 5);

      (* 4. store statistics + retrieval *)
      let (chunks, docs) = Lwt_main.run (Store.stats store) in
      Printf.printf "  store stats: %d chunks, %d docs\n%!" chunks docs;
      check "stats: two documents" (docs = 2);
      check "stats: chunk count consistent" (chunks = s1.Pipeline.chunks + n3);

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
        (List.for_all (fun h -> h.Store.form = "8-K") hk);

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
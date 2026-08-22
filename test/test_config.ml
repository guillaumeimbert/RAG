module T = Alcotest.V1

let write_env (s : string) : string =
  let p = Filename.concat (Filename.get_temp_dir_name ()) (Printf.sprintf "cfg-test-%d.env" (Unix.getpid ())) in
  let oc = Out_channel.open_text p in
  Out_channel.output_string oc s;
  Out_channel.close oc;
  p

let required_body =
  "DATABASE_URL=postgresql://u:p@localhost:5432/db\n"
  ^ "OPENAI_BASE_URL=http://127.0.0.1:9999/v1/\n"
  ^ "OPENAI_API_KEY=key123\n"
  ^ "LLM_MODEL=llm-m\n"
  ^ "EMBEDDING_MODEL=emb-m\n"
  ^ "EMBEDDING_DIM=64\n"
  ^ "SEC_USER_AGENT=me@example.com\n"
  ^ "SEC_BROWSE_EDGAR_BASE=http://sec/cgi-bin/browse-edgar\n"
  ^ "SEC_DAILY_INDEX_BASE=http://sec\n"
  ^ "SEC_SUBMISSIONS_BASE=http://sec/submissions\n"
  ^ "SEC_FTS_BASE=http://sec/full-text/search\n"
  ^ "SEC_ARCHIVES_BASE=http://sec/Archives/edgar/data\n"
  ^ "FORMS=10-K, 8-K ,, 10-Q\n"
  ^ "CHUNK_SIZE=900\n"
  ^ "CHUNK_OVERLAP=120\n"
  ^ "TOP_K=5\n"

let tests : (string * unit T.test_case list) list =
  [
    (
      "load",
      [
        T.test_case "all fields" `Quick (fun () ->
            let p = write_env required_body in
            let cfg = Config.load ~env_file:p () in
            T.check T.string "mismatch" "postgresql://u:p@localhost:5432/db" cfg.Config.database_url;
            (* trailing slash is stripped *)
            T.check T.string "mismatch" "http://127.0.0.1:9999/v1" cfg.Config.openai_base_url;
            T.check T.int "mismatch" 64 cfg.Config.embedding_dim;
            T.check (T.list T.string) "mismatch" [ "10-K"; "8-K"; "10-Q" ] cfg.Config.forms;
            T.check T.int "mismatch" 5 cfg.Config.top_k;
            T.check T.string "mismatch" "https://www.sec.gov/files/company_tickers.json" cfg.Config.sec_company_tickers_url;
            Sys.remove p);
        T.test_case "optional tickers URL is honoured" `Quick (fun () ->
            let p = write_env (required_body ^ "SEC_COMPANY_TICKERS_URL=http://x/t.json\n") in
            T.check T.string "mismatch" "http://x/t.json" (Config.load ~env_file:p ()).Config.sec_company_tickers_url;
            Sys.remove p);
        T.test_case "missing required var raises Missing" `Quick (fun () ->
            let body = Stringx.replace required_body ~sub:"TOP_K=5\n" ~by:"" in
            let p = write_env body in
            T.match_raises "raises" Tcheck.missing_pred (fun () -> ignore (Config.load ~env_file:p ()));
            Sys.remove p);
        T.test_case "non-integer raises Failure" `Quick (fun () ->
            let body = Stringx.replace required_body ~sub:"EMBEDDING_DIM=64" ~by:"EMBEDDING_DIM=abc" in
            let p = write_env body in
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Config.load ~env_file:p ()));
            Sys.remove p);
      ] );
    (
      "E.of_file",
      [
        T.test_case "comments, blanks, export, quotes" `Quick (fun () ->
            let p =
              write_env
                ("  # a comment\n"
                 ^ "\n"
                 ^ "export EXPORTED=1\n"
                 ^ "QUOTED_D=\"hello world\"\n"
                 ^ "QUOTED_S='single quoted'\n"
                 ^ "NO_EQUALS_LINE\n"
                 ^ "=novalue\n"
                 ^ "PLAIN=keep me  \n") in
            let e = Config.E.of_file p in
            T.check (T.option T.string) "mismatch" (Some "1") (Config.E.get e "EXPORTED");
            T.check (T.option T.string) "mismatch" (Some "hello world") (Config.E.get e "QUOTED_D");
            T.check (T.option T.string) "mismatch" (Some "single quoted") (Config.E.get e "QUOTED_S");
            T.check (T.option T.string) "mismatch" None (Config.E.get e "NO_EQUALS_LINE");
            T.check (T.option T.string) "mismatch" (Some "keep me") (Config.E.get e "PLAIN");
            T.check (T.option T.string) "mismatch" None (Config.E.get e "NOPE");
            Sys.remove p);
        T.test_case "require on absent raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.missing_pred (fun () -> ignore (Config.E.require [] "X")));
        T.test_case "require_csv trims and drops empties" `Quick (fun () ->
            T.check (T.list T.string) "mismatch" [ "b"; "c" ] (Config.E.require_csv [ ("A", " b , , c ") ] "A"));
      ] );
  ]
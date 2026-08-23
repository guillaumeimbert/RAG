(** Fixture helpers. Tests may run with any working directory (manual runs
    from the workspace root or [test/], [dune runtest] from the build dir),
    so all paths are anchored on the project root, located by walking up
    from the current directory to the one containing [schema/]. *)

let root =
  let rec up d =
    if Sys.file_exists (Filename.concat d "schema/0001_init.sql")
    then d
    else
      let p = Filename.dirname d in
      if p = d then failwith "test_fixtures: cannot locate the project root (schema/0001_init.sql)"
      else up p in
  up (Unix.getcwd ())

let fix name = Filename.concat root ("test/fixtures/" ^ name)

let schema_file name = Filename.concat root ("schema/" ^ name)

let read_text (path : string) : string =
  let ic = In_channel.open_text path in
  try
    let s = In_channel.input_all ic in
    In_channel.close ic;
    s
  with e ->
    (In_channel.close ic; raise e)

let read_bin (path : string) : string =
  let ic = In_channel.open_bin path in
  try
    let s = In_channel.input_all ic in
    In_channel.close ic;
    s
  with e ->
    (In_channel.close ic; raise e)

(** Read a fixture as a [Config.t] with every SEC/OpenAI URL pointed at
    [base] (the mock servers in [e2e]). *)
let cfg_for (base : string) (over : Config.t -> Config.t) : Config.t =
  over
    {
      Config.database_url = "postgresql://unused";
      openai_base_url = base ^ "/v1";
      openai_api_key = "test-key";
      openai_embed_base_url = base ^ "/v1";
      openai_embed_api_key = "test-key";
      llm_model = "mock-llm";
      embedding_model = "mock-embed";
      embedding_dim = 64;
      sec_user_agent = "test@example.com (test)";
      sec_browse_edgar_base = base ^ "/cgi-bin/browse-edgar";
      sec_daily_index_base = base;
      sec_submissions_base = base ^ "/submissions";
      sec_fts_base = base ^ "/full-text/search";
      sec_archives_base = base ^ "/Archives/edgar/data";
      sec_company_tickers_url = base ^ "/files/company_tickers.json";
      forms = [ "10-K"; "10-Q"; "8-K" ];
      chunk_size = 900;
      chunk_overlap = 120;
      top_k = 8;
      min_similarity = 0.0;
    }
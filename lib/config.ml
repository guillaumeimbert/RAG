(** Configuration loaded from a [.env] file.

    Every behavioural knob (database, inference server, models, SEC
    endpoints, chunking, retrieval) is configured here; see
    {[.env.example]} at the project root. The only assumption about the
    inference server is that it speaks the OpenAI HTTP API (vLLM, ninfer,
    llama.cpp, a cloud provider, ...). *)

(** Raised when a required variable is absent from the .env file. *)
exception Missing of string

module E : sig
  type env = (string * string) list

  val of_file : string -> env
  val get : env -> string -> string option
  val require : env -> string -> string
  val require_int : env -> string -> int
  val require_csv : env -> string -> string list
end = struct
  type env = (string * string) list

  let parse_line line =
    let line = String.trim line in
    if line = "" || Stringx.starts_with line ~prefix:"#" then None
    else
      let line =
        if Stringx.starts_with line ~prefix:"export "
        then Stringx.drop_prefix line ~prefix:"export "
        else line
      in
      match Stringx.lsplit2 line ~on:'=' with
      | None -> None
      | Some (key, value) ->
        let key = String.trim key in
        let v = String.trim value in
        let value =
          if String.length v >= 2
             && Char.equal (String.get v 0) (String.get v (String.length v - 1))
             && (Char.equal (String.get v 0) '"'
                || Char.equal (String.get v 0) '\'')
          then String.sub v 1 (String.length v - 2)
          else v
        in
        if key = "" then None else Some (key, value)

  let of_file path =
    let ic = In_channel.open_text path in
    let r =
      try
        let pairs = ref [] in
        let rec loop () =
          match In_channel.input_line ic with
          | None -> ()
          | Some line ->
            (match parse_line line with
             | None -> ()
             | Some p -> pairs := p :: !pairs);
            loop ()
        in
        loop ();
        List.rev !pairs
      with e ->
        In_channel.close ic;
        raise e
    in
    In_channel.close ic;
    r

  let get e k = List.assoc_opt k e

  let require e k =
    match get e k with
    | Some v -> v
    | None -> raise (Missing k)

  let require_int e k =
    match get e k with
    | None -> raise (Missing k)
    | Some v ->
      (try int_of_string v
       with Failure _ -> failwith (k ^ " must be an integer, got '" ^ v ^ "'"))

  let require_csv e k =
    require e k
    |> Re.split (Re.compile (Re.char ','))
    |> List.map String.trim
    |> List.filter (fun x -> x <> "")
end

type t = {
  database_url : string;
  openai_base_url : string;
  openai_api_key : string;
  (** Embedding endpoint (base URL + key). Defaults to the chat endpoint;
      set [OPENAI_EMBED_BASE_URL] / [OPENAI_EMBED_API_KEY] when embeddings
      are served by a different server. *)
  openai_embed_base_url : string;
  openai_embed_api_key : string;
  llm_model : string;
  embedding_model : string;
  embedding_dim : int;
  sec_user_agent : string;
  sec_browse_edgar_base : string;
  sec_daily_index_base : string;
  sec_submissions_base : string;
  sec_fts_base : string;
  sec_archives_base : string;
  (** Full URL of the SEC's company-tickers file (ticker -> CIK). Defaults
      to https://www.sec.gov/files/company_tickers.json when the variable
      is absent from .env. *)
  sec_company_tickers_url : string;
  forms : string list;
  chunk_size : int;
  chunk_overlap : int;
  top_k : int;
  (** Minimum cosine similarity (0..1) for a hit to be returned. A query whose
      nearest chunks score below this returns nothing ("no results") instead
      of feeding the LLM irrelevant material. 0.0 disables the filter. *)
  min_similarity : float;
}

let load ?(env_file = ".env") () : t =
  let e = E.of_file env_file in
  let openai_base_url = Stringx.drop_suffix ~suffix:"/" (E.require e "OPENAI_BASE_URL") in
  let openai_api_key = E.require e "OPENAI_API_KEY" in
  {
    database_url = E.require e "DATABASE_URL";
    openai_base_url;
    openai_api_key;
    openai_embed_base_url =
      (match E.get e "OPENAI_EMBED_BASE_URL" with
       | Some u -> Stringx.drop_suffix ~suffix:"/" u
       | None -> openai_base_url);
    openai_embed_api_key =
      (match E.get e "OPENAI_EMBED_API_KEY" with
       | Some k -> k
       | None -> openai_api_key);
    llm_model = E.require e "LLM_MODEL";
    embedding_model = E.require e "EMBEDDING_MODEL";
    embedding_dim = E.require_int e "EMBEDDING_DIM";
    sec_user_agent = E.require e "SEC_USER_AGENT";
    sec_browse_edgar_base = E.require e "SEC_BROWSE_EDGAR_BASE";
    sec_daily_index_base = E.require e "SEC_DAILY_INDEX_BASE";
    sec_submissions_base = E.require e "SEC_SUBMISSIONS_BASE";
    sec_fts_base = E.require e "SEC_FTS_BASE";
    sec_archives_base = E.require e "SEC_ARCHIVES_BASE";
    sec_company_tickers_url =
      (match E.get e "SEC_COMPANY_TICKERS_URL" with
       | Some u -> u
       | None -> "https://www.sec.gov/files/company_tickers.json");
    forms = E.require_csv e "FORMS";
    chunk_size = E.require_int e "CHUNK_SIZE";
    chunk_overlap = E.require_int e "CHUNK_OVERLAP";
    top_k = E.require_int e "TOP_K";
    min_similarity =
      (match E.get e "MIN_SIMILARITY" with
       | Some v ->
         (try float_of_string v
          with Failure _ -> failwith ("MIN_SIMILARITY must be a float, got '" ^ v ^ "'"))
       | None -> 0.0);
  }

(** True when [form] should be ingested: when its normalised code is in
    [FORMS] (both sides normalised, so [FORMS=13G] also matches EDGAR's
    "SCHEDULE 13G"), or when [FORMS] contains the special value ["ALL"]
    (ingest every form). *)
let forms_allow (t : t) (form : string) : bool =
  let f = Ownership.norm_form form in
  List.mem "ALL" t.forms || List.mem f (List.map Ownership.norm_form t.forms)
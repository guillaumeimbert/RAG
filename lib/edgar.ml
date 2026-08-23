(** SEC EDGAR client: discovery, fetch and parse.

    Fair access (https://www.sec.gov/os/fair-access):
    - static User-Agent with contact information (from .env);
    - a single shared client-side throttle keeping us at ~9 req/s;
    - retries with backoff on 429/5xx (in [Net]).

    Sources (see docs/adr/ADR-001-ingest-discovery.md):
    - daily-index sitemaps — the complete filing list per business day;
    - filing index pages — metadata + primary document name;
    - per-CIK submissions JSON — full filing history of one company;
    - company-tickers.json — ticker -> CIK resolution. *)

(** One filing as listed by a daily-index sitemap. *)
type filing = {
  accession : string;
  (** e.g. 0000320193-25-000079 *)
  cik : string;
  (** unpadded, as it appears in the archive URL path *)
  index_url : string;
}

(** Parsed metadata of one filing (from its EDGAR index page, or built
    directly from the submissions JSON). *)
type filing_index = {
  accession : string;
  cik : string;
  (** 10-digit, zero padded *)
  company : string;
  form : string;
  filed_at : Date.t;
  report_date : Date.t option;
  primary_document : string;
  primary_description : string;
  index_url : string;
  ticker : string;
  (** from the submissions JSON when available; "" otherwise *)
}

(** Raised when a sitemap is missing (holiday / weekend) or a page cannot
    be parsed. *)
exception Failure of string

let pad_cik cik = Stringx.pad_left ~length:10 ~with_:'0' cik

(* One shared throttle for all SEC traffic: ~9 req/s max. *)
let throttle = Net.Throttle.create ()

let sec_get cfg url =
  Net.get ~throttle ~headers:(Net.sec_headers ~user_agent:cfg.Config.sec_user_agent ()) url

(* ------------------------------------------------------------------ *)
(* Daily-index sitemaps -> filings of one day                           *)
(* ------------------------------------------------------------------ *)

let listing_url cfg day =
  let ymd =
    Printf.sprintf "%04d%02d%02d" day.Date.year day.Date.month day.Date.day
  in
  let year = Printf.sprintf "%04d" day.Date.year in
  let q = Date.quarter day in
  (* Layout (verified live 2026-08-22): daily-index/{YYYY}/QTR{q}/sitemap.{YYYYMMDD}.xml.
     The date-first form returns 403. *)
  cfg.Config.sec_daily_index_base
  ^ "/" ^ year ^ "/QTR" ^ string_of_int q ^ "/sitemap." ^ ymd ^ ".xml"

let https base =
  if Stringx.starts_with base ~prefix:"http://"
  then "https://" ^ Stringx.drop_prefix base ~prefix:"http://"
  else base

let filing_re =
  Re.compile
    Re.(seq [
         str "<loc>";
         group (Re.Pcre.re "https?://[^<]+");
         str "/Archives/edgar/data/";
         group (Re.Pcre.re "[0-9]+");
         str "/";
         group (Re.Pcre.re "[0-9]+-[0-9]+-[0-9]+");
         str "-index.htm";
         str "</loc>";
       ])

(** [parse_sitemap xml] parses a daily-index sitemap body into the filings
    it lists (deduplicated on accession, document order). HTTP URLs are
    upgraded to HTTPS. This is the pure core of [filings_of_day]; the
    fixture test pins the sitemap format. *)
let parse_sitemap (xml : string) : filing list =
  let seen = ref (Hashtbl.create 4096) in
  let filings = ref [] in
  List.iter
    (fun g ->
      let base = https (Re.Group.get g 1) in
      let cik = Re.Group.get g 2 in
      let acc = Re.Group.get g 3 in
      if not (Hashtbl.mem !seen acc) then
        ( Hashtbl.add !seen acc ();
          filings
            := { accession = acc; cik; index_url =
                  base ^ "/Archives/edgar/data/" ^ cik ^ "/" ^ acc ^ "-index.htm" } :: !filings ))
    (Re.all filing_re xml);
  List.rev !filings

(** [filings_of_day cfg day] = every filing listed for [day] (all forms).
    Raises [Failure] when the sitemap does not exist (holiday/weekend). *)
let filings_of_day cfg (day : Date.t) : filing list Lwt.t =
  let url = listing_url cfg day in
  Lwt.catch
    (fun () -> Lwt.bind (sec_get cfg url) (fun xml -> Lwt.return (parse_sitemap xml)))
    (function
      | Net.Http_error e when e.status = 404 ->
        Lwt.fail (Failure ("no sitemap for " ^ Date.to_string day ^ " (holiday?)"))
      | e -> Lwt.fail e)

(* ------------------------------------------------------------------ *)
(* Filing index page parsing                                            *)
(* ------------------------------------------------------------------ *)

let strip_tags s =
  Re.replace_string (Re.compile (Re.Pcre.re "<[^>]*>")) ~by:"" s

let form_re =
  Re.compile
    Re.(seq [
         str "<div id=\"formName\"";
         Re.Pcre.re "[^>]*>";
         Re.Pcre.re "[ \t\n]*";
         str "<strong>";
         Re.Pcre.re "[ \t\n]*";
         str "Form";
         Re.Pcre.re " +";
         group (Re.Pcre.re "[A-Za-z0-9/-]+");
       ])

let info_re field =
  Re.compile
    Re.(seq [
         str "<div class=\"infoHead\">";
         str field;
         str "</div>";
         Re.Pcre.re "[ \t\n]*";
         str "<div class=\"info\">";
         Re.Pcre.re "[ \t\n]*";
         group (Re.Pcre.re "[0-9]{4}-[0-9]{2}-[0-9]{2}");
       ])

let filing_date_re = info_re "Filing Date"
let period_of_report_re = info_re "Period of Report"

let company_re =
  Re.compile
    Re.(seq [
         str "<span class=\"companyName\"";
         Re.Pcre.re "[^>]*>";
         Re.Pcre.re "[ \t\n]*";
         group (Re.Pcre.re "[^<]+");
       ])

let filer_re =
  Re.compile (Re.Pcre.re "\\s*\\(Filer[^)]*\\)")

let first_table s =
  match
    Re.exec_opt
      (Re.compile (Re.Pcre.re ~flags:[`DOTALL] "<table[ 	\n/][^>]*>.*?</table>"))
      s
  with
  | Some g -> Re.Group.get g 0
  | None -> ""

let row_re = Re.compile Re.(str "</tr>")
let cell_re =
  Re.compile
    (Re.Pcre.re ~flags:[`DOTALL] "<td[ 	\n/][^>]*>(.*?)</td>")
let doc_link_re =
  Re.compile (Re.Pcre.re "<a[^>]+>([^<]+)</a>")

(** [parse_index filing html] extracts metadata from a filing index page.
    Returns [None] when the page has no recognisable primary document. *)
let parse_index (filing : filing) (html : string) : filing_index option =
  let get re =
    match Re.exec_opt re html with
    | Some g -> Some (Re.Group.get g 1)
    | None -> None
  in
  let form = get form_re in
  let filed_at_s = get filing_date_re in
  let company_s = get company_re in
  match (form, filed_at_s, company_s) with
  | Some form, Some filed_at_s, Some company_s ->
    let filed_at =
      (* [Stdlib.Failure]: this module declares its own [Failure], which
         would otherwise shadow the stdlib exception raised by
         [Date.of_string] (and then never be caught). *)
      (try Some (Date.of_string filed_at_s)
       with Stdlib.Failure _ -> None)
    in
    let report_date =
      Option.bind (get period_of_report_re)
        (fun s -> (try Some (Date.of_string s) with Stdlib.Failure _ -> None))
    in
    (* primary document = the row of the first table whose Type equals the
       form; its Document cell links the .htm file. *)
    let table = first_table html in
    let rows = Re.split row_re table in
    let primary =
      List.fold_left
        (fun acc row ->
          match acc with
          | Some _ -> acc
          | None ->
            let cells =
              List.map (fun g -> String.trim (strip_tags (Re.Group.get g 1)))
                (Re.all cell_re row)
            in
            match cells with
            | _seq :: _desc :: _doc :: typ :: _ when typ = form ->
              (match Re.exec_opt doc_link_re row with
               | Some g -> Some (String.trim (Re.Group.get g 1), _desc)
               | None -> None)
            | _ -> None)
        None
        rows
    in
    let result =
      match (filed_at, primary) with
      | Some filed_at, Some (doc, desc) ->
        Some
          {
            accession = filing.accession;
            cik = pad_cik filing.cik;
            company = Re.replace_string filer_re ~by:"" company_s |> String.trim;
            form;
            filed_at;
            report_date;
            primary_document = doc;
            primary_description = desc;
            index_url = filing.index_url;
            ticker = "";
          }
      | _ -> None
    in
    result
  | _ -> None

(** Fetch + parse the index page of [filing]. [None] for pages with no form
    metadata (letter/anonymous filings: no form, no HTML documents) — there
    is nothing to ingest for those. *)
let filing_index_of cfg (filing : filing) : filing_index option Lwt.t =
  Lwt.map (parse_index filing) (sec_get cfg filing.index_url)

(** Fetch a static document (filing HTML) from the EDGAR archives, under
    the shared throttle. *)
let get_document cfg url =
  Net.get ~throttle ~headers:(Net.sec_headers ~user_agent:cfg.Config.sec_user_agent ()) url

(** Fetch any SEC URL under the shared throttle (probe/inspection tool). *)
let fetch cfg url = get_document cfg url

(** Accession number without dashes (the archives directory name). *)
let acc_undashed (acc : string) : string =
  acc |> String.to_seq |> Seq.filter (fun c -> c <> '-') |> String.of_seq

(** Root directory (trailing slash) of an accession in the EDGAR archives.

    The index page is [data/{cik}/{acc-dashed}-index.htm], but the filing
    documents live in [data/{cik}/{acc-undashed}/]. We reuse the index URL's
    prefix (up to the cik) and swap in the undashed accession. *)
let accession_root (fi : filing_index) : string =
  let prefix = Stringx.drop_suffix ~suffix:(fi.accession ^ "-index.htm") fi.index_url in
  prefix ^ acc_undashed fi.accession ^ "/"

(** URL of the primary document (as listed in the index). *)
let primary_url (fi : filing_index) : string = accession_root fi ^ fi.primary_document

(** Directory (trailing slash) containing the primary document. *)
let doc_dir (fi : filing_index) : string =
  Stringx.drop_suffix ~suffix:fi.primary_document (primary_url fi)

(** URL of the raw XML data document of an ownership filing.

    Modern 13F-HR / 13G / 13D filings carry their machine-readable data XML
    at the accession root as [primary_doc.xml]; the XSL-rendered variant
    listed as primaryDocument ([xsl.../primary_doc.xml]) is styled HTML, not
    data. Live-verified 2026-07 against accessions 0001045810-26-000065
    (13F-HR) and 0001045810-26-000062 (13G). *)
let primary_xml_url (fi : filing_index) : string = accession_root fi ^ "primary_doc.xml"

(** URL of the 13F information table (accession root; the [xsl.../]
    variant is styled HTML). *)
let info_table_url (fi : filing_index) : string = accession_root fi ^ "information_table.xml"

(** Public index page of an accession number: the accession starts with
    the filer CIK (unpadded), which is the directory in the archives. *)
let index_url_of_accession (base : string) (accession : string) : string =
  let cik =
    (match String.index_from_opt accession 0 '-' with
     | Some i -> String.sub accession 0 i
     | None -> accession)
  in
  base ^ "/" ^ cik ^ "/" ^ acc_undashed accession ^ "-index.htm"

(* ------------------------------------------------------------------ *)
(* Per-CIK submissions JSON and ticker resolution                       *)
(* ------------------------------------------------------------------ *)

(** [submissions cfg cik] = the full per-CIK filing history JSON
    (submissions JSON v3; [cik] may be unpadded). *)
let submissions cfg (cik : string) : Yojson.Safe.t Lwt.t =
  let url =
    cfg.Config.sec_submissions_base ^ "/CIK" ^ pad_cik cik ^ ".json"
  in
  Lwt.bind (sec_get cfg url) (fun s ->
    match Yojson.Safe.from_string s with
    | j -> Lwt.return j
    | exception Yojson.Json_error _ ->
      Lwt.fail (Failure ("invalid JSON in submissions for CIK " ^ cik)))

(** [find_cik tickers_json ticker] resolves [ticker] to a zero-padded CIK
    inside a company-tickers document (pure; the format is pinned by the
    fixture test). The real file (see [Config.sec_company_tickers_url]) is
    a flat object keyed by index:
    {"0": {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc."}, ...}. *)
let find_cik (tickers_json : Yojson.Safe.t) (ticker : string) : string option =
  let rows =
    match tickers_json with
    | `Assoc a -> List.map snd a
    | other ->
      raise (Json.Expecting { got = Json.show other; want = "a tickers object" })
  in
  let t = String.uppercase_ascii ticker in
  let found = ref None in
  List.iter
    (fun row ->
      if Option.is_none !found
      then
        (match row with
         | `Assoc fields ->
           (match (List.assoc_opt "ticker" fields, List.assoc_opt "cik_str" fields) with
            | Some (`String s), Some c when s = t ->
              found := Some (pad_cik (string_of_int (Json.int c)))
            | _ -> ())
         | _ -> ()))
    rows;
  !found

(** [cik_of_ticker cfg ticker] resolves a ticker to a 10-digit CIK via the
    SEC's company-tickers file. [None] if unknown. *)
let cik_of_ticker cfg (ticker : string) : string option Lwt.t =
  Lwt.bind (sec_get cfg cfg.Config.sec_company_tickers_url) (fun s ->
    match Yojson.Safe.from_string s with
    | exception Yojson.Json_error _ ->
      Lwt.fail (Failure "invalid JSON in company-tickers file")
    | j -> Lwt.return (find_cik j ticker))

(* ------------------------------------------------------------------ *)
(* Company-tickers file: cached, bidirectional (ticker and name)       *)
(* ------------------------------------------------------------------ *)

(** Normalised company name: upper case, letters and digits only
    ("Nebius Group N.V." and "NEBIUS GROUP NV" -> "NEBIUSGROUPNV"). *)
let norm_name (s : string) : string =
  s
  |> String.uppercase_ascii
  |> String.to_seq
  |> Seq.filter (fun c -> (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
  |> String.of_seq

module Tickers : sig
  type t
  val of_json : Yojson.Safe.t -> t
  val find : t -> string -> string option
  (** [find t key] resolves an upper-cased ticker OR a normalised name
      ([norm_name]) to a 10-digit zero-padded CIK. *)
  val prefix : t -> string -> string option
  (** [prefix t key] = the CIK when exactly one company's normalised name
      starts with [key] (>= 4 chars, strictly longer name). Ambiguous or
      short keys resolve to [None]. *)
end = struct
  type t = {
    by_ticker : (string, string) Hashtbl.t;
    by_name : (string, string) Hashtbl.t;
  }

  let find t key =
    (match Hashtbl.find_opt t.by_ticker key with
     | Some c -> Some c
     | None -> Hashtbl.find_opt t.by_name key)

  let prefix t key =
    if String.length key < 4
    then None
    else
      let matches = ref [] in
      Hashtbl.iter
        (fun name cik ->
          if String.length name > String.length key
          && String.starts_with name ~prefix:key
          then matches := cik :: !matches)
        t.by_name;
      (match !matches with
       | [ c ] -> Some c
       | _ -> None)

  let of_json (j : Yojson.Safe.t) : t =
    let by_ticker = Hashtbl.create 16384 in
    let by_name = Hashtbl.create 16384 in
    let rows =
      match j with
      | `Assoc a -> List.map snd a
      | other ->
        raise (Json.Expecting { got = Json.show other; want = "a tickers object" })
    in
    List.iter
      (fun row ->
        match row with
        | `Assoc fields ->
          (match
             ( List.assoc_opt "ticker" fields
             , List.assoc_opt "cik_str" fields
             , List.assoc_opt "title" fields )
           with
           | Some (`String ticker), Some c, Some (`String title) ->
             let cik = pad_cik (string_of_int (Json.int c)) in
             let t = String.uppercase_ascii ticker in
             if not (Hashtbl.mem by_ticker t) then Hashtbl.add by_ticker t cik;
             let n = norm_name title in
             if n <> "" && not (Hashtbl.mem by_name n) then Hashtbl.add by_name n cik
           | _ -> ())
        | _ -> ())
      rows;
    { by_ticker; by_name }
end

(* One shared cached copy per process (the file changes rarely; a per-
   process cache keeps an ingest run at one extra request). Keyed by URL
   so a cfg change invalidates it. *)
let tickers_cache : (string * Tickers.t) option ref = ref None

(** [tickers_of cfg] = the company-tickers file as a [Tickers.t], fetched
    once per process. *)
let tickers_of cfg : Tickers.t Lwt.t =
  match !tickers_cache with
  | Some (url, t) when url = cfg.Config.sec_company_tickers_url -> Lwt.return t
  | _ ->
    Lwt.bind (sec_get cfg cfg.Config.sec_company_tickers_url) (fun s ->
      match Yojson.Safe.from_string s with
      | exception Yojson.Json_error _ ->
        Lwt.fail (Failure "invalid JSON in company-tickers file")
      | j ->
        let t = Tickers.of_json j in
        tickers_cache := Some (cfg.Config.sec_company_tickers_url, t);
        Lwt.return t)

(** [resolve cfg key] = ticker (any case) or company name (any case) ->
    10-digit padded CIK, via the cached company-tickers file. *)
let resolve cfg (key : string) : string option Lwt.t =
  Lwt.bind (tickers_of cfg) (fun t ->
    let direct = Tickers.find t (String.uppercase_ascii key) in
    Lwt.return
      (match direct with
       | Some c -> Some c
       | None ->
         (match Tickers.find t (norm_name key) with
          | Some c -> Some c
          | None -> Tickers.prefix t (norm_name key))))
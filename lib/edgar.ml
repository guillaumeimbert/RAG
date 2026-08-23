(** SEC EDGAR client: discovery, fetch and parse.

    Fair access (https://www.sec.gov/os/fair-access):
    - static User-Agent with contact information (from .env);
    - a single shared client-side throttle keeping us at ~9 req/s;
    - retries with backoff on 429/5xx (in [Net]).

    Sources (see docs/adr/ADR-001-ingest-discovery.md):
    - daily-index master — the complete filing list per business day, with a
      Form Type column used to pre-filter by [Config.forms];
    - filing index pages — metadata + primary document name;
    - per-CIK submissions JSON — full filing history of one company;
    - company-tickers.json — ticker -> CIK resolution. *)

(** One filing as listed by the daily-index master. *)
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
  info_table_document : string option;
  (** the 13F information-table XML as named in the index's
      "INFORMATION TABLE" row (e.g. "infotable.xml"); [None] when the index
      lists no such document *)
  index_url : string;
  ticker : string;
  (** from the submissions JSON when available; "" otherwise *)
}

(** Raised when the daily master index is missing (holiday / weekend) or a
    page cannot be parsed. *)
exception Failure of string

let pad_cik cik = Stringx.pad_left ~length:10 ~with_:'0' cik

(* One shared throttle for all SEC traffic: ~9 req/s max. *)
let throttle = Net.Throttle.create ()

let sec_get cfg url =
  Net.get ~throttle ~headers:(Net.sec_headers ~user_agent:cfg.Config.sec_user_agent ()) url

(* ------------------------------------------------------------------ *)
(* Daily-index master -> allow-listed filings of one day                    *)
(* ------------------------------------------------------------------ *)

(** [master_url cfg day] = the URL of the daily-index *master* [.idx] for
    [day]. The daily index uses *calendar* quarters (QTR1 = Jan–Mar, QTR4 =
    Oct–Dec); layout verified live 2026-08-22:
    daily-index/{YYYY}/QTR{q}/master.{YYYYMMDD}.idx. The master index lists
    the same filings as the sitemap (identical unique accessions) but also
    carries the *Form Type*, which lets [master_of_day] pre-filter by
    [Config.forms] before any index page is fetched. *)
let master_url cfg day =
  let ymd =
    Printf.sprintf "%04d%02d%02d" day.Date.year day.Date.month day.Date.day
  in
  let year = Printf.sprintf "%04d" day.Date.year in
  let q = Date.quarter day in
  cfg.Config.sec_daily_index_base
  ^ "/" ^ year ^ "/QTR" ^ string_of_int q ^ "/master." ^ ymd ^ ".idx"

(** One row of the daily master index. The *Form Type* is already present,
    which is what makes form pre-filtering possible. *)
type master_row = {
  cik : string;
  company : string;
  form_type : string;
  date : string;
  accession : string;
}

let is_digits s =
  let l = String.length s in
  if l = 0 then false
  else
    let r = ref true in
    for i = 0 to l - 1 do
      let c = String.get s i in
      if c < '0' || c > '9' then r := false
    done;
    !r

(** [data_row_of line] recognizes one master-index data row by shape — five
    pipe-separated fields, a numeric CIK, a YYYYMMDD date, and a file name
    containing a directory — so the five header lines and the `---`
    separator are skipped without hard-coding their position. The file name
    is the canonical archive path ({cik}/{accession}.txt); the accession is
    its base name with the [.txt] dropped. *)
let data_row_of (line : string) : master_row option =
  let parts = String.split_on_char '|' (String.trim line) in
  match parts with
  | [ cik; company; form; date; file ]
    when is_digits cik && is_digits date && String.length date = 8
         && String.contains file '/' ->
    let comps = String.split_on_char '/' (String.trim file) in
    let n = List.length comps in
    if n < 2 then None
    else
      let base = List.nth comps (n - 1) in
      Some
        { cik = String.trim cik;
          company = String.trim company;
          form_type = String.trim form;
          date = String.trim date;
          accession =
            if Stringx.ends_with base ~suffix:".txt"
            then Stringx.drop_suffix base ~suffix:".txt"
            else base; }
  | _ ->
    None

(** [parse_master body] parses a daily master-index body into [master_row]s
    (file order). Header lines and the separator are ignored by
    [data_row_of]. This is the pure core of [master_of_day]; it does no I/O
    and the fixture test pins the format. *)
let parse_master (body : string) : master_row list =
  List.filter_map data_row_of (String.split_on_char '\n' body)

(** [master_filings cfg rows] = the [filing]s actually to fetch: rows whose
    normalized form is in [cfg.forms] (or every row when forms is "ALL"),
    deduplicated by accession (the master index lists the same accession
    once per related CIK). Each [filing.index_url] is the index page on
    [sec_archives_base]. This is where the pre-filter happens: ~3,000
    rows/day shrink to the few hundred allow-listed ones before any index
    page is requested. 13F amendments (13F-HR/A) are discarded here even
    when allow-listed: they are deliberately unsupported (see
    [Ownership.is_13f_amendment]), so dropping them before the index download
    avoids an unnecessary fetch that the ingest guard would skip anyway. *)
let master_filings cfg (rows : master_row list) : filing list =
  let seen = Hashtbl.create 1024 in
  let out = ref [] in
  List.iter
    (fun r ->
      if Config.forms_allow cfg r.form_type
         && not (Ownership.is_13f_amendment r.form_type)
         && not (Hashtbl.mem seen r.accession)
      then
        ( Hashtbl.add seen r.accession ();
          out
            := { accession = r.accession;
                 cik = r.cik;
                 index_url =
                   cfg.Config.sec_archives_base ^ "/" ^ r.cik ^ "/"
                   ^ r.accession ^ "-index.htm"; } :: !out ))
    rows;
  List.rev !out

(** [master_of_day cfg day] = every *allow-listed* filing listed for [day].
    Fetches the master index once and pre-filters by [Config.forms] (via
    [master_filings]); index pages are fetched later by the pipeline, only
    for the survivors. Raises [Failure] when the master index does not
    exist (holiday/weekend) or lists no rows. *)
let master_of_day cfg (day : Date.t) : filing list Lwt.t =
  let url = master_url cfg day in
  Lwt.catch
    (fun () ->
      Lwt.bind (sec_get cfg url) (fun body ->
        match parse_master body with
        | [] -> Lwt.fail (Failure ("no filings found in master index for " ^ url))
        | rows -> Lwt.return (master_filings cfg rows)))
    (function
      | Net.Http_error e when e.status = 404 ->
        Lwt.fail (Failure ("no master index for " ^ Date.to_string day ^ " (holiday?)"))
      | e -> Lwt.fail e)

(* ------------------------------------------------------------------ *)
(* Filing index page parsing                                            *)
(* ------------------------------------------------------------------ *)

let strip_tags s =
  Re.replace_string (Re.compile (Re.Pcre.re "<[^>]*>")) ~by:"" s

(** Form name as shown in the formName box ("Form SCHEDULE 13G", "Form
    13F-HR", ...). The code itself may contain spaces ("SCHEDULE 13G", "SC
    13D"), so capture everything up to the closing tag; the caller trims. *)
let form_re =
  Re.compile
    Re.(seq [
         str "<div id=\"formName\"";
         Re.Pcre.re "[^>]*>";
         Re.Pcre.re "[ \t\n]*";
         str "<strong>";
         Re.Pcre.re "[ \t\n]*";
         str "Form";
         Re.Pcre.re "[ \t]+";
         group (Re.Pcre.re "[^<]+");
       ])

(** [13F]/[13G]/[13D] (and their "SCHEDULE ..." / "SC ..." spellings). Their
    structured data lives in a [*.xml] document that the index lists right
    beside a [*.html] "friendly" twin under the SAME Type; prose filings
    (10-K, 8-K, ...) have a single primary document. Used to pick the data
    file in [parse_index] without importing the domain [Ownership] module
    into this low-level parser. *)
let is_ownership_form (form : string) : bool =
  let s = String.trim form in
  let s =
    if Stringx.starts_with s ~prefix:"SCHEDULE "
    then Stringx.drop_prefix s ~prefix:"SCHEDULE "
    else s
  in
  let s =
    if Stringx.starts_with s ~prefix:"SC "
    then Stringx.drop_prefix s ~prefix:"SC "
    else s
  in
  Stringx.starts_with s ~prefix:"13F"
  || Stringx.starts_with s ~prefix:"13G"
  || Stringx.starts_with s ~prefix:"13D"

(** [head_opt l] = [Some (List.hd l)] or [None] if [l] is empty. (The
    switch's standard library lacks [List.hd_opt]. *)
let head_opt (l : 'a list) : 'a option =
  match l with
  | [] -> None
  | x :: _ -> Some x

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
  let form = Option.map String.trim (get form_re) in
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
       form; its Document cell links the file. For ownership filings
       (13F/13G/13D) the index lists the data .xml right beside a ".html"
       friendly twin under the SAME Type; the structured data is the .xml,
       so prefer it. Prose filings have a single primary document, so the
       first match is used. *)
    let table = first_table html in
    let rows = Re.split row_re table in
    let row_doc (row : string) : (string * string) option =
      let cells =
        List.map (fun g -> String.trim (strip_tags (Re.Group.get g 1)))
          (Re.all cell_re row)
      in
      match cells with
      | _seq :: _desc :: _doc :: typ :: _ when typ = form ->
        (match Re.exec_opt doc_link_re row with
         | Some g -> Some (String.trim (Re.Group.get g 1), _desc)
         | None -> None)
      | _ -> None
    in
    let matches = List.filter_map row_doc rows in
    let primary =
      if is_ownership_form form
      then
        (* prefer the data .xml over the .html twin; fall back to the first
           match if the index lists no .xml *)
        (match List.find_opt (fun (doc, _desc) -> Stringx.ends_with doc ~suffix:".xml") matches with
         | Some m -> Some m
         | None -> head_opt matches)
      else head_opt matches
    in
    (* 13F information table = the "INFORMATION TABLE" row whose document is
       the .xml (the .html twin is styled output). Its filename varies
       ("infotable.xml", "information_table.xml", ...), so take it from the
       index rather than assuming one. *)
    let info_table_doc =
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
            | _seq :: _desc :: _ :: typ :: _
              when String.uppercase_ascii typ = "INFORMATION TABLE" ->
              (match Re.exec_opt doc_link_re row with
               | Some g ->
                 let d = String.trim (Re.Group.get g 1) in
                 if Stringx.ends_with d ~suffix:".xml" then Some d else None
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
            info_table_document = info_table_doc;
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

    The document name is the one the index page selected for the primary
    document ([fi.primary_document], a bare file name such as
    "primary_doc.xml"). The XSL-rendered variant listed by the submissions
    API ([xsl.../primary_doc.xml]) is styled HTML, not data, and is never
    fetched (see [resolve_ownership_index], which replaces that path with
    the index-named data document before it is used). Live-verified
    2026-08 against NVDA accessions 0001045810-26-000065 (13F-HR) and
    0001045810-26-000062 (13G). *)
let primary_xml_url (fi : filing_index) : string = accession_root fi ^ fi.primary_document

(** URL of the 13F information table (accession root; the [xsl.../] variant
    is styled HTML). The filename is taken from the index's "INFORMATION
    TABLE" row when present ([fi.info_table_document]); real filings name it
    "infotable.xml", so the conventional "information_table.xml" is only a
    fallback (a 404 on it is treated upstream as "no positions"). *)
let info_table_url (fi : filing_index) : string =
  let doc = Option.value ~default:"information_table.xml" fi.info_table_document in
  accession_root fi ^ doc

(** Resolve the 13F information-table URL asynchronously. The day/master path
    has already parsed the index, so [fi.info_table_document] is set and no
    extra fetch happens. The per-CIK submissions path does not parse the index
    page, so fetch + parse it here to learn the filename; a 404 or an
    unparseable index falls back to [info_table_url] ("information_table.xml"). *)
let info_table_url_of cfg (fi : filing_index) : string Lwt.t =
  match fi.info_table_document with
  | Some _ -> Lwt.return (info_table_url fi)
  | None ->
    let filing = { accession = fi.accession; cik = fi.cik; index_url = fi.index_url } in
    Lwt.catch
      (fun () ->
        Lwt.map
          (fun parsed ->
            match parsed with
            | Some p -> info_table_url p
            | None -> info_table_url fi)
          (filing_index_of cfg filing))
      (function
        | Net.Http_error e when e.status = 404 -> Lwt.return (info_table_url fi)
        | e -> Lwt.fail e)

(** Ensure [fi.primary_document] names the data document at the accession
    root (a bare file name), not the XSL-rendered HTML path listed by the
    submissions API.

    The master/day path parses the index page, so [fi.primary_document] is
    already the bare data document and this is a no-op. The per-CIK
    submissions path stores the submissions API's [primaryDocument]
    (e.g. "xslForm13F_X02/primary_doc.xml"), which is an HTML path (it
    contains a "/") — verified 2026-08: that file is a <html> document, not
    the data XML. Detect that and fetch + parse the index page to learn the
    real data document name (and, for 13F, the information-table name). On a
    404 or an unparseable index, fall back to the conventional
    "primary_doc.xml" so a missing index does not mask the data document. *)
let resolve_ownership_index cfg (fi : filing_index) : filing_index Lwt.t =
  if not (String.contains fi.primary_document '/')
  then Lwt.return fi
  else
    let fallback = { fi with primary_document = "primary_doc.xml" } in
    let filing =
      { accession = fi.accession; cik = fi.cik; index_url = fi.index_url }
    in
    Lwt.catch
      (fun () ->
        Lwt.bind (filing_index_of cfg filing) (fun parsed ->
          match parsed with
          | Some p ->
            Lwt.return
              { fi with
                primary_document = p.primary_document;
                info_table_document = p.info_table_document }
          | None -> Lwt.return fallback))
      (function
        | Net.Http_error e when e.status = 404 -> Lwt.return fallback
        | e -> Lwt.fail e)

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
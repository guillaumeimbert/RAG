(** Ingestion pipeline: discover -> fetch -> parse -> chunk -> embed -> store.

    Entry points:
    - [ingest_day]   — every filing of one business day (daily-index sitemap);
    - [ingest_range] — [ingest_day] over a date range, skipping weekends and
      holidays (missing sitemaps);
    - [ingest_cik]   — the recent filing history of one company
      (submissions JSON; no index-page fetch).

    Idempotency: documents are keyed by accession number
    ([UNIQUE (doc_id, chunk_index)]); documents already present in the store
    are skipped so re-runs do not re-embed. *)

module F = Format

(** Lwt sequencing operator, used in the pipeline entry points. *)
let ( >>= ) = Lwt.( >>= )

type job = {
  index : Edgar.filing_index;
  primary_url : string;
}

let make_job (index : Edgar.filing_index) : job =
  { index; primary_url = Edgar.primary_url index }

type stats = {
  docs : int;
  chunks : int;
  skipped : int;
  events : int;
  (** structured 13D/13G ownership events stored *)
  positions : int;
  (** structured 13F holdings stored *)
}

let empty_stats = { docs = 0; chunks = 0; skipped = 0; events = 0; positions = 0 }

let show_stats s =
  F.asprintf "docs=%d chunks=%d events=%d positions=%d skipped=%d"
    s.docs
    s.chunks
    s.events
    s.positions
    s.skipped

(* ------------------------------------------------------------------ *)
(* Embedding                                                            *)
(* ------------------------------------------------------------------ *)

(** Embed [texts] in batches of 16, returning (text, vector) pairs in input
    order. *)
let embed_all (cfg : Config.t) (texts : string list) : (string * float list) list Lwt.t =
  if List.length texts <= 16
  then
    Lwt.bind (Openai.embed ~cfg texts) (fun vecs ->
      Lwt.return (List.combine texts vecs))
  else
    let rec go (texts : string list) acc =
      match texts with
      | [] -> Lwt.return (List.rev acc)
      | _ ->
        let head = List.take 16 texts in
        let tail = List.drop 16 texts in
        Lwt.bind (Openai.embed ~cfg head) (fun vecs ->
          go tail (List.combine head vecs @ acc))
    in
    go texts []

(* ------------------------------------------------------------------ *)
(* One document                                                         *)
(* ------------------------------------------------------------------ *)

(** Result of one [ingest_job] attempt. *)
type job_result =
  | Skipped
  (** form not in [FORMS], the filing is already in the store, or an error
      made it unusable. *)
  | Ingested of {
      chunks : int;
      events : int;
      positions : int;
    }

(** [Ownership.event] -> upsertable row (dates as ISO strings). *)
let event_row (e : Ownership.event) : Store.own_event_row =
  { Store.accession = e.accession
  ; form = e.form
  ; event_date = Date.to_string e.event_date
  ; filed_at = Date.to_string e.filed_at
  ; filer_cik = e.filer_cik
  ; filer_name = e.filer_name
  ; subject_cik = e.subject_cik
  ; subject_name = e.subject_name
  ; subject_cusip = e.subject_cusip
  ; class_name = e.class_name
  ; shares = e.shares
  ; percent = e.percent
  ; passive = e.passive
  ; is_amendment = e.is_amendment
  ; index_url = e.index_url }

(** Chunk, embed and store ready [blocks]. Returns the number of chunks
    stored. *)
let store_blocks (store : Store.t) (job : job) (blocks0 : Chunk.block list) : int Lwt.t =
  let cfg = store.Store.cfg in
  let index = job.index in
  let blocks =
    blocks0 |> Chunk.chunks ~size:cfg.Config.chunk_size ~overlap:cfg.Config.chunk_overlap
  in
  let n = List.length blocks in
  if n = 0
  then Lwt.return 0
  else
    Lwt.bind (embed_all cfg (List.map (fun b -> b.Chunk.text) blocks)) (fun embedded ->
      let rows =
        List.mapi
          (fun i (b, (_text, vec)) ->
            { Store.doc_id = index.accession
            ; company = index.company
            ; cik = index.cik
            ; ticker = index.ticker
            ; form = index.form
            ; filed_at = Date.to_string index.filed_at
            ; section = b.Chunk.section
            ; chunk_index = i
            ; text = b.Chunk.text
            ; embedding = Store.vector_to_string vec })
          (List.combine blocks embedded)
      in
      Lwt.bind (Store.upsert_chunks store rows) (fun () -> Lwt.return n))

(** Narrative forms (10-K / 10-Q / 8-K / ...): HTML -> text -> chunks ->
    vectors. *)
let ingest_prose_filing (store : Store.t) (job : job) : job_result Lwt.t =
  Lwt.bind (Edgar.get_document store.Store.cfg job.primary_url) (fun html ->
    store_blocks store job (Html_text.of_html html)
    >>= fun n -> Lwt.return (Ingested { chunks = n; events = 0; positions = 0 }))

(** 13G / 13D: raw XML -> structured ownership events; the narrative
    (items / comments) additionally goes through the vector path so it
    stays answerable by the LLM. *)
let ingest_13gd (store : Store.t) (job : job) : job_result Lwt.t =
  let cfg = store.Store.cfg in
  let index = job.index in
  let meta =
    { Ownership.accession = index.accession
    ; filed_at = index.filed_at
    ; index_url = index.index_url }
  in
  Lwt.bind (Edgar.get_document cfg (Edgar.primary_xml_url index)) (fun xml ->
    let (events, prose) =
      (match Ownership.classify index.form with
       | Ownership.Form13d -> Ownership.parse_13d xml ~meta ~form:index.form
       | _ -> Ownership.parse_13g xml ~meta ~form:index.form)
    in
    let rows = List.map event_row events in
    Lwt.bind (Store.upsert_own_events store rows) (fun () ->
      if prose = ""
      then Lwt.return (Ingested { chunks = 0; events = List.length events; positions = 0 })
      else
        store_blocks store job
          [{ Chunk.section = Ownership.norm_form index.form ^ " — items & comments";
             text = prose }]
        >>= fun n ->
        Lwt.return (Ingested { chunks = n; events = List.length events; positions = 0 })))

(** 13F-HR: raw XML -> structured holdings. Issuer CIKs are resolved
    best-effort against the company-tickers file; unresolved issuers keep
    an empty CIK and remain queryable by name. *)
let ingest_13f (store : Store.t) (job : job) : job_result Lwt.t =
  let cfg = store.Store.cfg in
  let index = job.index in
  let meta =
    { Ownership.accession = index.accession
    ; filed_at = index.filed_at
    ; index_url = index.index_url }
  in
  (* A missing information table (rare) does not block the cover: the
     filing is recorded with zero positions. *)
  let table_opt : string option Lwt.t =
    Lwt.catch
      (fun () ->
        Edgar.get_document cfg (Edgar.info_table_url index)
        >>= fun s -> Lwt.return (Some s))
      (function
        | Net.Http_error e ->
          Printf.eprintf "  %s: no information table (%s)\n%!" index.accession (Net.show_error e);
          Lwt.return None
        | e -> Lwt.fail e)
  in
  Lwt.bind (Edgar.get_document cfg (Edgar.primary_xml_url index)) (fun cover_xml ->
    Lwt.bind table_opt (fun table ->
      let t13f = Ownership.parse_13f cover_xml ~meta ~form:index.form table in
      let resolve (name : string) : string Lwt.t =
        if name = ""
        then Lwt.return ""
        else
          Lwt.bind (Edgar.resolve cfg name) (function
            | Some c -> Lwt.return c
            | None ->
              Printf.eprintf "  %s: issuer not resolved: %s\n%!" index.accession name;
              Lwt.return "")
      in
      Lwt_list.map_s resolve (List.map (fun (p : Ownership.position) -> p.issuer_name) t13f.positions)
      >>= fun ciks ->
      let rows =
        List.map2
          (fun (p : Ownership.position) (cik : string) ->
            { Store.accession = index.accession
            ; filer_cik = t13f.filer_cik
            ; filer_name = t13f.filer_name
            ; period = Date.to_string t13f.period
            ; filed_at = Date.to_string index.filed_at
            ; issuer_name = p.issuer_name
            ; issuer_cusip = p.issuer_cusip
            ; issuer_cik = cik
            ; class_name = p.class_name
            ; value_usd = p.value_usd
            ; shares = p.shares
            ; prnamt_type = p.prnamt_type
            ; discretion = p.discretion
            ; vote_sole = p.vote_sole
            ; vote_shared = p.vote_shared
            ; vote_none = p.vote_none })
          t13f.positions ciks
      in
      Lwt.bind (Store.upsert_holdings store rows) (fun () ->
        Lwt.return (Ingested { chunks = 0; events = 0; positions = List.length rows }))))

(** Route one filing to its pipeline by form class. *)
let ingest_job (store : Store.t) (job : job) : job_result Lwt.t =
  let cfg = store.Store.cfg in
  let doc_id = job.index.accession in
  if Config.forms_allow cfg job.index.form = false
  then Lwt.return Skipped
  else
    Lwt.bind (Store.filing_exists store doc_id) (fun exists ->
      if exists
      then Lwt.return Skipped
      else
        match Ownership.classify job.index.form with
        | Ownership.Prose -> ingest_prose_filing store job
        | Ownership.Form13g | Ownership.Form13d -> ingest_13gd store job
        | Ownership.Form13f -> ingest_13f store job)

(** [ingest_job] with per-filing fault isolation: a fetch/parse error
    skips that filing (with a warning) instead of aborting the run. *)
let ingest_job_safe (store : Store.t) (job : job) : job_result Lwt.t =
  Lwt.catch
    (fun () -> ingest_job store job)
    (function
      | Edgar.Failure msg ->
        Printf.eprintf "  skip %s: %s\n%!" job.index.accession msg;
        Lwt.return Skipped
      | Net.Http_error e ->
        Printf.eprintf "  skip %s: %s\n%!" job.index.accession (Net.show_error e);
        Lwt.return Skipped
      | e ->
        Printf.eprintf "  skip %s: %s\n%!" job.index.accession (Printexc.to_string e);
        Lwt.return Skipped)

(* ------------------------------------------------------------------ *)
(* Per-day                                                              *)
(* ------------------------------------------------------------------ *)

let ingest_day (store : Store.t) (day : Date.t) : stats Lwt.t =
  let cfg = store.Store.cfg in
  let stats = ref empty_stats in
  Lwt.bind (Edgar.filings_of_day cfg day) (fun filings ->
    Lwt_list.iter_s
      (fun f ->
        Lwt.bind (Edgar.filing_index_of cfg f) (fun index ->
          match index with
          | (* index page without form metadata (letter/anonymous filing):
               nothing to ingest *)
            None ->
            stats := { !stats with skipped = !stats.skipped + 1 };
            Lwt.return_unit
          | Some index ->
            if Config.forms_allow cfg index.form
            then
              Lwt.bind (ingest_job_safe store (make_job index)) (fun r ->
                (match r with
                 | Skipped -> stats := { !stats with skipped = !stats.skipped + 1 }
                 | Ingested r ->
                   stats :=
                     { !stats with
                       docs = !stats.docs + 1;
                       chunks = !stats.chunks + r.chunks;
                       events = !stats.events + r.events;
                       positions = !stats.positions + r.positions });
                Lwt.return_unit)
            else (stats := { !stats with skipped = !stats.skipped + 1 }; Lwt.return_unit)))
      filings
    >>= fun () -> Lwt.return !stats)

let business_days (from : Date.t) (to_ : Date.t) : Date.t list =
  let rec go acc d =
    if Date.to_string d > Date.to_string to_ then List.rev acc
    else
      let next = go (if Date.is_weekend d then acc else d :: acc) (Date.next d) in
      next
  in
  go [] from

let ingest_range (store : Store.t) (from : Date.t) (to_ : Date.t) : stats Lwt.t =
  let days = business_days from to_ in
  let stats = ref empty_stats in
  let add (s : stats) =
    stats :=
      { docs = !stats.docs + s.docs;
        chunks = !stats.chunks + s.chunks;
        skipped = !stats.skipped + s.skipped;
        events = !stats.events + s.events;
        positions = !stats.positions + s.positions }
  in
  Lwt_list.iter_s
    (fun day ->
      Lwt.catch
        (fun () ->
          Lwt.bind (ingest_day store day) (fun s ->
            Printf.eprintf "  %s  %s\n%!" (Date.to_string day) (show_stats s);
            add s;
            Lwt.return_unit))
        (function
          | Edgar.Failure msg ->
            Printf.eprintf "  %s  %s\n%!" (Date.to_string day) msg;
            Lwt.return_unit
          | e -> Lwt.fail e))
    days
    >>= fun () -> Lwt.return !stats

(* ------------------------------------------------------------------ *)
(* Per-CIK                                                              *)
(* ------------------------------------------------------------------ *)

let pad10 s = Stringx.pad_left ~length:10 ~with_:'0' s

(** Remove leading zeros from a zero-padded CIK (keep at least one digit). *)
let drop_leading_zeros s =
  let l = String.length s in
  if l = 0 then s
  else
    let i = ref 0 in
    while !i < l - 1 && String.get s !i = '0' do
      incr i
    done;
    String.sub s !i (l - !i)

(** One row of the padded submissions arrays, in field order.
    (accession, form, filed_at, report_at, doc, description). *)
type submissions_row =
  ((((Yojson.Safe.t * Yojson.Safe.t) * (Yojson.Safe.t * Yojson.Safe.t))
    * Yojson.Safe.t)
   * Yojson.Safe.t)

(** Build [job] records straight from a submissions JSON "recent" block
    (no index-page fetch). Filing dates that do not parse are dropped. *)
let jobs_of_submissions (cfg : Config.t) (j : Yojson.Safe.t) : job list =
  let name = Json.string (Json.member "name" j) in
  let tickers =
    match Json.member "tickers" j with
    | `List l ->
      (match l with
       | `String s :: _ -> s
       | _ -> "")
    | `String s -> s
    | _ -> ""
  in
  let cik = pad10 (Json.string (Json.member "cik" j)) in
  let recent = Json.member "recent" (Json.member "filings" j) in
  (* Per-field arrays of the submissions API: a missing key means "no
     values" (unlike the index page, this endpoint omits optional fields
     entirely), so use a tolerant lookup instead of the strict [Json.member]. *)
  let member_opt obj key =
    match obj with
    | `Assoc l -> List.assoc_opt key l
    | _ -> None
  in
  let arr key =
    match member_opt recent key with
    | Some (`List l) -> l
    | _ -> []
  in
  let accessions = arr "accessionNumber" in
  let forms = arr "form" in
  let filed_ats = arr "filingDate" in
  let report_ats = arr "reportDate" in
  let docs = arr "primaryDocument" in
  let descs = arr "primaryDocDescription" in
  (* Pad each field array to the accession count and zip into rows: one
     O(n) pass (the submissions arrays are mostly full; short ones are
     the optional ones, missing values become ""). *)
  let n = List.length accessions in
  let pad (l : Yojson.Safe.t list) : Yojson.Safe.t list =
    let m = List.length l in
    if m >= n then l else l @ List.init (n - m) (fun _ -> `String "")
  in
  let rows : submissions_row list =
    List.combine
      (List.combine
         (List.combine
            (List.combine (pad accessions) (pad forms))
            (List.combine (pad filed_ats) (pad report_ats)))
         (pad docs))
      (pad descs)
  in
  List.filter_map
    (fun (r : submissions_row) ->
      let ((((acc, form), (filed_s, report_s)), doc), desc) = r in
      match (acc, form, filed_s, report_s, doc, desc) with
      | `String accession, `String form, `String filed_s, _, `String doc, _
        when doc <> "" ->
        (try
           let index =
             {
               Edgar.accession;
               cik;
               company = name;
               form;
               filed_at = Date.of_string filed_s;
               report_date =
                 (match report_s with
                  | `String s when s <> "" -> Some (Date.of_string s)
                  | _ -> None);
               primary_document = doc;
               primary_description = (match desc with `String s -> s | _ -> "");
               index_url =
                 cfg.Config.sec_archives_base
                 ^ "/"
                 ^ drop_leading_zeros cik
                 ^ "/"
                 ^ accession
                 ^ "-index.htm";
               ticker = tickers;
             }
           in
           Some (make_job index)
         with Failure _ -> None)
      | _ -> None)
    rows

(** Ingest the recent filings of one CIK. [?limit] bounds the number of
    filings (the most recent are first). *)
let ingest_cik ?limit (store : Store.t) (cik : string) : stats Lwt.t =
  let cfg = store.Store.cfg in
  let stats = ref empty_stats in
  Lwt.bind (Edgar.submissions cfg cik) (fun j ->
    let jobs =
      (match limit with
       | Some n -> List.take n (jobs_of_submissions cfg j)
       | None -> jobs_of_submissions cfg j)
    in
    Lwt_list.iter_s
      (fun job ->
        Lwt.bind (ingest_job_safe store job) (fun r ->
          (match r with
           | Skipped -> stats := { !stats with skipped = !stats.skipped + 1 }
           | Ingested r ->
             stats :=
               { !stats with
                 docs = !stats.docs + 1;
                 chunks = !stats.chunks + r.chunks;
                 events = !stats.events + r.events;
                 positions = !stats.positions + r.positions });
          Lwt.return_unit))
      jobs
    >>= fun () -> Lwt.return !stats)
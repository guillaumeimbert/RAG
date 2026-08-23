(** Ingestion pipeline: discover -> fetch -> parse -> chunk -> embed -> store.

    Entry points:
    - [ingest_day]   — every *allow-listed* filing of one business day
      (daily-index master, pre-filtered by [Config.forms]);
    - [ingest_range] — [ingest_day] over a date range, skipping weekends and
      holidays (missing master index);
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
  failed : int;
  (** jobs that errored after discovery (embedding/DB); nothing partial
      was stored (writes are transactional), re-running retries them *)
  events : int;
  (** structured 13D/13G ownership events stored *)
  positions : int;
  (** structured 13F holdings stored *)
}

let empty_stats = { docs = 0; chunks = 0; skipped = 0; failed = 0; events = 0; positions = 0 }

let show_stats s =
  F.asprintf "docs=%d chunks=%d events=%d positions=%d skipped=%d failed=%d"
    s.docs
    s.chunks
    s.events
    s.positions
    s.skipped
    s.failed

(* ------------------------------------------------------------------ *)
(* Embedding                                                            *)
(* ------------------------------------------------------------------ *)

(** Embed [texts] in batches of 16, returning (text, vector) pairs in input
    order. Batches are embedded in order and their results concatenated in
    order (pairs within a batch are ordered by the server's [index] field,
    enforced by [Openai.embed]). *)
let embed_all (cfg : Config.t) (texts : string list) : (string * float list) list Lwt.t =
  if List.length texts <= 16
  then
    Lwt.bind (Openai.embed ~cfg texts) (fun vecs ->
      Lwt.return (List.combine texts vecs))
  else
    let rec go (batches : (string * float list) list list) (texts : string list) =
      match texts with
      | [] -> Lwt.return (List.concat (List.rev batches))
      | _ ->
        let head = List.take 16 texts in
        let tail = List.drop 16 texts in
        Lwt.bind (Openai.embed ~cfg head) (fun vecs ->
          go (List.combine head vecs :: batches) tail)
    in
    go [] texts

(* ------------------------------------------------------------------ *)
(* One document                                                         *)
(* ------------------------------------------------------------------ *)

(** Result of one [ingest_job] attempt. *)
type job_result =
  | Skipped
  (** form not in [FORMS], the filing is already in the store, or a
      fetch/parse failure. In all these cases nothing was written, so the
      next run simply retries (or, for [FORMS], skips again). *)
  | Failed of string
  (** an embedding or database failure. Writes are transactional, so no
      partial state was left behind either — but the run did not complete
      cleanly and the caller should surface it (and re-run to retry). *)
  | Ingested of {
      chunks : int;
      events : int;
      positions : int;
    }

(** Fold one [ingest_job_safe] result into a [stats] accumulator. A job that
    persisted zero rows (a 13F with no information table, or a filing with no
    extractable text) is counted as [skipped] rather than [docs]: nothing was
    stored, so it is not a document — and, being absent from the store, the
    "already ingested" check re-attempts it on the next run. *)
let apply_result (stats : stats ref) (res : job_result) : unit =
  match res with
  | Skipped -> stats := { !stats with skipped = !stats.skipped + 1 }
  | Failed _ -> stats := { !stats with failed = !stats.failed + 1 }
  | Ingested r ->
    if r.chunks + r.events + r.positions = 0
    then stats := { !stats with skipped = !stats.skipped + 1 }
    else
      stats :=
        { !stats with
          docs = !stats.docs + 1;
          chunks = !stats.chunks + r.chunks;
          events = !stats.events + r.events;
          positions = !stats.positions + r.positions }

(** [Ownership.event] -> upsertable row (dates as ISO strings). *)
let event_row (event_index : int) (e : Ownership.event) : Store.own_event_row =
  { Store.accession = e.accession
  ; event_index
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

(** Chunk [blocks0] to the configured size and embed every chunk. All
    external I/O (the embedding calls) happens here, *before* anything is
    written to the store. Returns (block, vector) pairs in input order. *)
let embed_blocks (store : Store.t) (blocks0 : Chunk.block list) :
    (Chunk.block * float list) list Lwt.t =
  let cfg = store.Store.cfg in
  let blocks =
    blocks0 |> Chunk.chunks ~size:cfg.Config.chunk_size ~overlap:cfg.Config.chunk_overlap
  in
  Lwt.bind (embed_all cfg (List.map (fun b -> b.Chunk.text) blocks)) (fun embedded ->
    Lwt.return (List.map (fun ((b : Chunk.block), (_text, vec)) -> (b, vec)) (List.combine blocks embedded)))

(** Build [chunk_row]s for one filing from (block, vector) pairs. *)
let chunk_rows (index : Edgar.filing_index) (embedded : (Chunk.block * float list) list) :
    Store.chunk_row list =
  List.mapi
    (fun i ((b : Chunk.block), vec) ->
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
    embedded

(** Narrative forms (10-K / 10-Q / 8-K / ...): HTML -> text -> chunks ->
    vectors. Fetch, parse and embed happen first; the chunks are then
    stored in one transaction. *)
let ingest_prose_filing ?force (store : Store.t) (job : job) : job_result Lwt.t =
  Lwt.bind (Edgar.get_document store.Store.cfg job.primary_url) (fun html ->
    Lwt.bind (embed_blocks store (Html_text.of_html html)) (fun embedded ->
      let rows = chunk_rows job.index embedded in
      Lwt.bind (Store.upsert_chunks ?force store job.index.accession rows) (fun () ->
        Lwt.return (Ingested { chunks = List.length rows; events = 0; positions = 0 }))))

(** 13G / 13D: raw XML -> structured ownership events; the narrative
    (items / comments) additionally goes through the vector path so it
    stays answerable by the LLM. The embedding happens before any write,
    and the events and chunks are stored in a single transaction: a
    failure at any point leaves nothing behind, so the next run retries
    the whole filing instead of finding it "already ingested". *)
let ingest_13gd ?force (store : Store.t) (job : job) : job_result Lwt.t =
  let cfg = store.Store.cfg in
  Lwt.bind (Edgar.resolve_ownership_index cfg job.index) (fun index ->
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
      let ev_rows = List.mapi (fun i e -> event_row i e) events in
      let embedded : (Chunk.block * float list) list Lwt.t =
        if prose = ""
        then Lwt.return []
        else
          embed_blocks store
            [{ Chunk.section = Ownership.norm_form index.form ^ " — items & comments";
               text = prose }]
      in
      Lwt.bind embedded (fun emb ->
        let ch_rows = chunk_rows index emb in
        Lwt.bind (Store.upsert_13gd ?force store index.accession ev_rows ch_rows) (fun () ->
          Lwt.return (Ingested { chunks = List.length ch_rows; events = List.length ev_rows; positions = 0 })))))

(** 13F-HR: raw XML -> structured holdings. Issuer CIKs are resolved
    best-effort against the company-tickers file; unresolved issuers keep
    an empty CIK and remain queryable by name. *)
let ingest_13f ?force (store : Store.t) (job : job) : job_result Lwt.t =
  let cfg = store.Store.cfg in
  Lwt.bind (Edgar.resolve_ownership_index cfg job.index) (fun index ->
    let meta =
      { Ownership.accession = index.accession
      ; filed_at = index.filed_at
      ; index_url = index.index_url }
    in
    (* A missing information table (rare) does not block the cover: the
       filing is recorded with zero positions. The filename is resolved from
       the index page by [Edgar.info_table_url_of] ("infotable.xml" in real
       filings); a 404 on it means "no positions". Only a 404 qualifies - any
       other HTTP error (5xx/429/timeout) is re-raised so the filing counts as
       failed instead of being dropped. *)
    let table_opt : string option Lwt.t =
      Lwt.bind (Edgar.info_table_url_of cfg index) (fun url ->
        Lwt.catch
          (fun () -> Edgar.get_document cfg url >>= fun s -> Lwt.return (Some s))
          (function
            | Net.Http_error e when e.Net.status = 404 ->
              Printf.eprintf "  %s: no information table (404)\n%!" index.accession;
              Lwt.return None
            | e -> Lwt.fail e))
    in
    Lwt.bind (Edgar.get_document cfg (Edgar.primary_xml_url index)) (fun cover_xml ->
      Lwt.bind table_opt (fun table ->
        let t13f = Ownership.parse_13f cover_xml ~meta ~form:index.form table in
        (* A 404 information table ([table = None]) is the ONLY benign "no
           positions" case: the cover is recorded with zero holdings. Any
           table that was actually downloaded (even an empty or
           whitespace-only body, which a 200 truncation can produce) but
           yields zero positions is truncated or schema-invalid; treating it
           as empty would hide a broken filing, so fail loudly (a re-run
           retries once the upstream is fixed). A genuinely empty holdings
           list is impossible in practice: a 13F is filed to disclose at
           least one holding. *)
        (match table with
         | None -> ()
         | Some _ ->
           if List.length t13f.positions > 0
           then ()
           else
             failwith
               (Printf.sprintf
                  "13F %s: information table downloaded but parsed to zero positions (truncated, schema-invalid, or empty)"
                  index.accession));
        (* Validate the parsed information table against the cover's summary
           totals ([tableEntryTotal] / [tableValueTotal]). A mismatch
           indicates a truncated or schema-invalid table; fail loudly so the
           filing is retried once the upstream is fixed. A missing total
           (None) is not validated. *)
        (match
           Ownership.validate_positions t13f.total_value_usd
             t13f.table_entry_total t13f.positions
         with
         | Some msg -> failwith (Printf.sprintf "13F %s: %s" index.accession msg)
         | None -> ());
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
          List.combine t13f.positions ciks
          |> List.mapi
               (fun i (p, cik) ->
                 let (p : Ownership.position) = p in
                 { Store.accession = index.accession
                 ; position_index = i
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
                 ; put_call = p.put_call
                 ; other_manager = p.other_manager
                 ; discretion = p.discretion
                 ; vote_sole = p.vote_sole
                 ; vote_shared = p.vote_shared
                 ; vote_none = p.vote_none })
        in
        Lwt.bind (Store.upsert_holdings ?force store index.accession rows) (fun () ->
          Lwt.return (Ingested { chunks = 0; events = 0; positions = List.length rows })))))

(** [ingest_job] routes one filing to its pipeline by form class (prose /
    13G-13D / 13F). 13F amendments are skipped before storage: the SEC Cover
    Page distinguishes two kinds (Form 13F FAQ) — a *restatement* resubmits
    and supersedes the complete original, while an *additive* amendment
    supplements it (listing only the positions that changed or were added).
    Storing both correctly would mean supersede-on-restatement and
    merge-on-additive; that is out of scope here, so 13F amendments are not
    stored at all. The stored report is therefore the original filing only —
    NOT a guaranteed-complete current snapshot once an amendment has been
    filed (a restatement makes it stale, an additive amendment leaves it
    incomplete). The default FORMS excludes amendments, so this only fires
    when the user opts in (FORMS=ALL or an explicit 13F-HR/A). *)
let ingest_job ?(force = false) (store : Store.t) (job : job) : job_result Lwt.t =
  let cfg = store.Store.cfg in
  let doc_id = job.index.accession in
  let route (f : bool) =
    match Ownership.classify job.index.form with
    | Ownership.Prose -> ingest_prose_filing ~force:f store job
    | Ownership.Form13g | Ownership.Form13d -> ingest_13gd ~force:f store job
    | Ownership.Form13f -> ingest_13f ~force:f store job
  in
  if Config.forms_allow cfg job.index.form = false
  then Lwt.return Skipped
  else if Ownership.is_13f_amendment job.index.form
  then (
    Printf.eprintf
      "  skip %s: 13F amendment (%s) not supported — a restatement or an additive amendment is not interpreted, so the stored original may be stale or incomplete after the amendment\n%!"
      doc_id job.index.form;
    Lwt.return Skipped)
  else
    (* A forced re-ingest bypasses the "already ingested" check and fully
       replaces the stored rows (see Store.upsert_* ~force). *)
    if force
    then route true
    else
      Lwt.bind (Store.filing_exists store doc_id) (fun exists ->
        if exists then Lwt.return Skipped else route false)

(** [ingest_job] with per-filing fault isolation: a fetch/parse error
    skips that filing (with a warning) instead of aborting the run; an
    embedding or database failure is reported as [Failed] (again without
    aborting the run) — in both cases nothing partial was written, so a
    re-run retries the filing. *)
let ingest_job_safe ?(force = false) (store : Store.t) (job : job) : job_result Lwt.t =
  Lwt.catch
    (fun () -> ingest_job ~force store job)
    (function
      | Edgar.Failure msg ->
        Printf.eprintf "  skip %s: %s\n%!" job.index.accession msg;
        Lwt.return Skipped
      | Net.Http_error e ->
        (* Inference-server HTTP errors are wrapped into [Openai.Api_error]
           upstream, so any [Net.Http_error] here is an EDGAR fetch failure.
           Only a genuine 404 (the document vanished, possibly a stale index
           entry) is a benign skip; any other status (5xx, 429 rate-limit,
           timeout) is a real failure of this filing. *)
        if e.Net.status = 404
        then (
          Printf.eprintf "  skip %s: %s\n%!" job.index.accession (Net.show_error e);
          Lwt.return Skipped)
        else (
          Printf.eprintf "  FAIL %s: %s\n%!" job.index.accession (Net.show_error e);
          Lwt.return (Failed ("EDGAR: " ^ Net.show_error e)))
      | Store.Db s ->
        Printf.eprintf "  FAIL %s: database: %s\n%!" job.index.accession s;
        Lwt.return (Failed ("database: " ^ s))
      | Openai.Api_error s ->
        Printf.eprintf "  FAIL %s: inference server: %s\n%!" job.index.accession s;
        Lwt.return (Failed ("inference server: " ^ s))
      | e ->
        Printf.eprintf "  FAIL %s: %s\n%!" job.index.accession (Printexc.to_string e);
        Lwt.return (Failed (Printexc.to_string e)))

(* ------------------------------------------------------------------ *)
(* Per-day                                                              *)
(* ------------------------------------------------------------------ *)

let ingest_day ?(force = false) (store : Store.t) (day : Date.t) : stats Lwt.t =
  let cfg = store.Store.cfg in
  let stats = ref empty_stats in
  Lwt.bind (Edgar.master_of_day cfg day) (fun filings ->
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
              Lwt.bind (ingest_job_safe ~force store (make_job index))
                (fun r -> apply_result stats r; Lwt.return_unit)
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

let ingest_range ?(force = false) (store : Store.t) (from : Date.t) (to_ : Date.t) : stats Lwt.t =
  let days = business_days from to_ in
  let stats = ref empty_stats in
  let add (s : stats) =
    stats :=
      { docs = !stats.docs + s.docs;
        chunks = !stats.chunks + s.chunks;
        skipped = !stats.skipped + s.skipped;
        failed = !stats.failed + s.failed;
        events = !stats.events + s.events;
        positions = !stats.positions + s.positions }
  in
  Lwt_list.iter_s
    (fun day ->
      Lwt.catch
        (fun () ->
          Lwt.bind (ingest_day ~force store day) (fun s ->
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
               (* the submissions JSON does not name the 13F information
                  table; [Pipeline.ingest_13f] resolves it from the index page *)
               info_table_document = None;
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
let ingest_cik ?limit ?(force = false) (store : Store.t) (cik : string) : stats Lwt.t =
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
        Lwt.bind (ingest_job_safe ~force store job)
          (fun r -> apply_result stats r; Lwt.return_unit))
      jobs
    >>= fun () -> Lwt.return !stats)
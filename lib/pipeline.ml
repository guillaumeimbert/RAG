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
}

let show_stats s =
  F.asprintf "docs=%d chunks=%d skipped=%d" s.docs s.chunks s.skipped

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

(** Fetch, parse, chunk, embed and store one filing. Returns the number of
    chunks stored (0 when the document was already in the store). *)
let ingest_job (store : Store.t) (job : job) : int Lwt.t =
  let cfg = store.Store.cfg in
  let index = job.index in
  let doc_id = index.accession in
  if Config.forms_allow cfg index.form = false
  then Lwt.return 0
  else
    Lwt.bind (Store.doc_exists store doc_id) (fun exists ->
      if exists
      then Lwt.return 0
      else
        Lwt.bind (Edgar.get_document cfg job.primary_url)
          (fun html ->
            let blocks =
              Html_text.of_html html
              |> Chunk.chunks ~size:cfg.Config.chunk_size ~overlap:cfg.Config.chunk_overlap
            in
            let n = List.length blocks in
            if n = 0
            then Lwt.return 0
            else
              Lwt.bind (embed_all cfg (List.map (fun b -> b.Chunk.text) blocks))
                (fun embedded ->
                  let rows =
                    List.mapi
                      (fun i (b, (text, vec)) ->
                        {
                          Store.doc_id;
                          company = index.company;
                          cik = index.cik;
                          ticker = index.ticker;
                          form = index.form;
                          filed_at = Date.to_string index.filed_at;
                          section = b.Chunk.section;
                          chunk_index = i;
                          text;
                          embedding = Store.vector_to_string vec;
                        })
                      (List.combine blocks embedded)
                  in
                  Lwt.bind (Store.upsert_chunks store rows) (fun () -> Lwt.return n))))

(* ------------------------------------------------------------------ *)
(* Per-day                                                              *)
(* ------------------------------------------------------------------ *)

let ingest_day (store : Store.t) (day : Date.t) : stats Lwt.t =
  let cfg = store.Store.cfg in
  let stats = ref { docs = 0; chunks = 0; skipped = 0 } in
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
              Lwt.bind (ingest_job store (make_job index)) (fun n ->
                if n > 0
                then (stats := { !stats with docs = !stats.docs + 1; chunks = !stats.chunks + n })
                else stats := { !stats with skipped = !stats.skipped + 1 };
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
  let stats = ref { docs = 0; chunks = 0; skipped = 0 } in
  let add (s : stats) =
    stats :=
      { docs = !stats.docs + s.docs;
        chunks = !stats.chunks + s.chunks;
        skipped = !stats.skipped + s.skipped }
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
  let pick l i = if i < List.length l then List.nth l i else `String "" in
  List.mapi
    (fun i acc ->
      match (acc, pick forms i, pick filed_ats i, pick docs i) with
      | `String accession, `String form, `String filed_s, `String doc
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
                 (match pick report_ats i with
                  | `String s when s <> "" -> Some (Date.of_string s)
                  | _ -> None);
               primary_document = doc;
               primary_description =
                 (match pick descs i with `String s -> s | _ -> "");
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
    accessions
  |> List.filter_map (fun x -> x)

let ingest_cik (store : Store.t) (cik : string) : stats Lwt.t =
  let cfg = store.Store.cfg in
  let stats = ref { docs = 0; chunks = 0; skipped = 0 } in
  Lwt.bind (Edgar.submissions cfg cik) (fun j ->
    let jobs = jobs_of_submissions cfg j in
    Lwt_list.iter_s
      (fun job ->
        Lwt.bind (ingest_job store job) (fun n ->
          if n > 0
          then (stats := { !stats with docs = !stats.docs + 1; chunks = !stats.chunks + n })
          else stats := { !stats with skipped = !stats.skipped + 1 };
          Lwt.return_unit))
      jobs
    >>= fun () -> Lwt.return !stats)
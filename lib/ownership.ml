(** Structured parsing of SEC ownership filings: Schedule 13D / 13G
    (who crossed the 5% beneficial-ownership threshold, and in which
    direction) and Form 13F (quarterly institutional position reports).

    Modern EDGAR submissions carry machine-readable XML for these forms
    (a [primary_doc.xml] for 13D/13G; a [primary_doc.xml] plus a holdings
    information table for 13F, whose file name varies by filer, e.g.
    [infotable.xml]). This module turns that XML into rows for the [ownership_events] and
    [holdings] tables (schema 0002) — structured retrieval by SQL instead
    of chunked prose. The human-readable parts of the filings (13G
    comments, 13D items such as funds source / transaction purpose) are
    returned alongside so the pipeline can also embed them as chunks.

    Layout reference (verified against real 2026 filings, pinned in
    test/fixtures/):
    - 13G: [formData/coverPageHeader] (class, event date, issuer) +
      [coverPageHeaderReportingPersonDetails] (the single filer's stake);
    - 13D: [formData/coverPageHeader] (event date, issuer) +
      [reportingPersons/reportingPersonInfo] (one per stake) +
      [items1To7] (prose);
    - 13F: [headerData/filerInfo] (CIK, period) +
      [formData/coverPage|summaryPage] + the information table.

    Field names differ subtly between the two schedules (13D uses
    [issuerCIK] / [percentOfClass] / [dateOfEvent]; 13G uses [issuerCik]
    / [classPercent] / [eventDateRequiresFilingThisStatement]) — the two
    parsers are kept separate rather than reconciled. *)

(* ------------------------------------------------------------------ *)
(* Form classification                                                 *)
(* ------------------------------------------------------------------ *)

type class_ =
  | Prose
  | Form13d
  | Form13g
  | Form13f

(** Strip the "SCHEDULE " / "SC " prefix and surrounding whitespace:
    EDGAR spells the same form as "SCHEDULE 13G" (submissions API) or
    "SC 13G" (older index pages). *)
let norm_form (f : string) : string =
  let s = String.trim f in
  let s' =
    if Stringx.starts_with s ~prefix:"SCHEDULE "
    then Stringx.drop_prefix s ~prefix:"SCHEDULE "
    else s
  in
  if Stringx.starts_with s' ~prefix:"SC "
  then Stringx.drop_prefix s' ~prefix:"SC "
  else s'

(** Which pipeline a filing goes through. Prefix-based: "13G-A" style
    variants and "13D-SC" etc. all classify by their leading code. *)
let classify (form : string) : class_ =
  let f = norm_form form in
  if Stringx.starts_with f ~prefix:"13D" then Form13d
  else if Stringx.starts_with f ~prefix:"13G" then Form13g
  else if Stringx.starts_with f ~prefix:"13F" then Form13f
  else Prose

(* ------------------------------------------------------------------ *)
(* SEC date fields                                                     *)
(* ------------------------------------------------------------------ *)

(* 13F uses "2026-06-30" (ISO); 13D/13G use "06/30/2026" (MM/DD/YYYY). *)
let of_sec_date (s : string) : Date.t option =
  let t = String.trim s in
  let via_sep (sep : char) : Date.t option =
    if String.contains t sep
    then
      let parts =
        String.split_on_char sep t |> List.filter (fun p -> String.trim p <> "")
      in
      (match parts with
       | [ m; d; y ] ->
         (try Some (Date.of_string (Printf.sprintf "%s-%s-%s" y m d))
          with Failure _ -> None)
       | _ -> None)
    else None
  in
  let via_iso =
    (try Some (Date.of_string t) with Failure _ -> None)
  in
  let fallback =
    (match via_sep '/' with
     | Some d -> Some d
     | None -> via_sep '-')
  in
  (match via_iso with
   | Some d -> Some d
   | None -> fallback)

(* ------------------------------------------------------------------ *)
(* Numbers                                                             *)
(* ------------------------------------------------------------------ *)

let int_of_text (s : string) : int option =
  let t =
    s
    |> String.to_seq
    |> Seq.filter (fun c -> (c >= '0' && c <= '9') || c = '-' || c = '.')
    |> String.of_seq
  in
  if t = "" then None
  else
    (try Some (int_of_string t)
     with Failure _ ->
       (* SEC sometimes writes whole numbers as "123.00". *)
       (try
          let f = float_of_string t in
          if Float.equal f (floor f) && abs_float f < 9.0e15
          then Some (int_of_float f)
          else None
        with Failure _ -> None))

let float_of_text (s : string) : float option =
  let t =
    s
    |> String.to_seq
    |> Seq.filter (fun c -> (c >= '0' && c <= '9') || c = '-' || c = '.')
    |> String.of_seq
  in
  if t = "" || t = "-" || t = "." then None
  else
    (try Some (float_of_string t)
     with Failure _ -> None)

(** [map_first f opts] = the first [Some] result of [f] over the present
    strings in [opts] (skipping [None]s and [None] results). Lets a field
    try several candidate elements in order. *)
let map_first (f : string -> 'a option) (opts : string option list) : 'a option =
  List.find_map (function Some s -> f s | None -> None) opts

(* ------------------------------------------------------------------ *)
(* 13D / 13G events                                                    *)
(* ------------------------------------------------------------------ *)

(** One beneficial-ownership statement (one reporting person's stake in
    one class of one issuer). [shares] / [percent] are [None] when the
    field is absent or unparseable. CIKs are 10-digit zero-padded. *)
type event = {
  accession : string;
  form : string;
  (** normalised form code: 13G, 13G/A, 13D, 13D/A *)
  event_date : Date.t;
  filed_at : Date.t;
  filer_cik : string;
  filer_name : string;
  subject_cik : string;
  subject_name : string;
  subject_cusip : string;
  class_name : string;
  shares : int option;
  percent : float option;
  passive : bool;
  (** 13G = passive investment; 13D = active/participating *)
  is_amendment : bool;
  index_url : string;
}

(** Filing metadata passed by the pipeline (all known before fetching). *)
type meta = {
  accession : string;
  filed_at : Date.t;
  index_url : string;
}

let is_amendment_of (form : string) : bool =
  let f = norm_form form in
  Stringx.ends_with f ~suffix:"/A"

(* Common 13D/13G scaffolding: the header carries the filer, the
    cover page the event date, class and issuer. Element spellings
    differ (13D: issuerCIK / dateOfEvent; 13G: issuerCik /
    eventDateRequiresFilingThisStatement) — try both. *)
let common (root : Xml.node) (meta : meta) (form : string) =
  let filer_cik =
    Xml.path_text [ "headerData"; "filerInfo"; "filer"; "filerCredentials"; "cik" ] root
    |> Option.value ~default:"-1"
    |> int_of_text
    |> Option.value ~default:(-1)
    |> string_of_int
    |> Stringx.pad_left ~length:10 ~with_:'0'
  in
  let cover =
    (match Xml.path [ "formData"; "coverPageHeader" ] root with
     | Some c -> c
     | None -> Xml.Text "")
  in
  let event_date =
    let from (s : string option) : Date.t option =
      (match s with
       | Some str -> of_sec_date str
       | None -> None)
    in
    (match from (Xml.child_text "eventDateRequiresFilingThisStatement" cover) with
     | Some d -> Some d
     | None -> from (Xml.child_text "dateOfEvent" cover))
    |> Option.value ~default:meta.filed_at
  in
  let class_name =
    Xml.child_text "securitiesClassTitle" cover |> Option.value ~default:""
  in
  let issuer =
    (match Xml.elem "issuerInfo" cover with
     | Some i -> i
     | None -> Xml.Text "")
  in
  let subject_cik =
    ( Xml.child_text "issuerCik" issuer
    |> Option.value ~default:(Xml.child_text "issuerCIK" issuer |> Option.value ~default:"-1")
    )
    |> int_of_text
    |> Option.value ~default:(-1)
    |> string_of_int
    |> Stringx.pad_left ~length:10 ~with_:'0'
  in
  let subject_name = Xml.child_text "issuerName" issuer |> Option.value ~default:"" in
  let subject_cusip =
    Xml.path_text [ "issuerCusips"; "issuerCusipNumber" ] issuer
    |> Option.value ~default:""
  in
  let is_am = is_amendment_of form in
  let make_event ~filer_cik ~filer_name ~shares ~percent ~passive =
    { accession = meta.accession
    ; form = norm_form form
    ; event_date
    ; filed_at = meta.filed_at
    ; filer_cik = filer_cik
    ; filer_name
    ; subject_cik
    ; subject_name
    ; subject_cusip
    ; class_name
    ; shares
    ; percent
    ; passive
    ; is_amendment = is_am
    ; index_url = meta.index_url }
  in
  (filer_cik, make_event)

(** [parse_13g xml ~meta ~form] — one 13G names exactly one filer and one
    class; returns ([events], [comments]) where comments is the prose of
    the filing (item 2 explanation, items 6/7, certification) for the
    vector path. *)
let parse_13g (xml : string) ~meta ~form : event list * string =
  let tree = Xml.parse xml in
  let root =
    match tree with
    | [] -> failwith "13G: empty document"
    | r :: _ -> r
  in
  let (filer_cik, make_event) = common root meta form in
  let details =
    (match Xml.path [ "formData"; "coverPageHeaderReportingPersonDetails" ] root with
     | Some d -> d
     | None -> Xml.Text "")
  in
  let filer_name =
    Xml.child_text "reportingPersonName" details |> Option.value ~default:""
  in
  let shares =
    Xml.child_text "reportingPersonBeneficiallyOwnedAggregateNumberOfShares" details
    |> Option.value ~default:""
    |> int_of_text
  in
  let percent =
    map_first float_of_text
      [
        Xml.child_text "classPercent" details;
        Xml.child_text "classPercent"
          (Xml.path [ "formData"; "items"; "item4" ] root
           |> Option.value ~default:(Xml.Text ""));
      ]
  in
  let items =
    (match Xml.path [ "formData"; "items" ] root with
     | Some i -> i
     | None -> Xml.Text "")
  in
  let opt_text (label : string) (s : string) : string option =
    if s = "" then None else Some (label ^ "\n\n" ^ s)
  in
  let parts =
    List.filter_map Fun.id
      [
        Xml.child_text "filingPersonName"
          (Xml.elem "item2" items |> Option.value ~default:(Xml.Text ""))
        |> Option.value ~default:""
        |> opt_text "Explanation";
        Xml.child_text "ownershipMoreThan5PercentOnBehalfOfAnotherPerson"
          (Xml.elem "item6" items |> Option.value ~default:(Xml.Text ""))
        |> Option.value ~default:""
        |> opt_text "Item 6";
        Xml.child_text "subsidiaryIdentificationAndClassification"
          (Xml.elem "item7" items |> Option.value ~default:(Xml.Text ""))
        |> Option.value ~default:""
        |> opt_text "Item 7";
        Xml.child_text "certifications"
          (Xml.elem "item10" items |> Option.value ~default:(Xml.Text ""))
        |> Option.value ~default:""
        |> opt_text "Item 10 certification";
      ]
  in
  let events =
    [
      make_event
        ~filer_cik
        ~filer_name
        ~shares
        ~percent
        ~passive:true;
    ]
  in
  (events, String.concat "\n\n\n" parts)

(* ------------------------------------------------------------------ *)
(* 13D                                                                 *)
(* ------------------------------------------------------------------ *)

(** [parse_13d xml ~meta ~form] — one or more reporting persons; returns
    ([events], [items_prose]) where items_prose is the 13D items text
    (explanatory note, funds source, transaction purpose, ...) for the
    vector path. *)
let parse_13d (xml : string) ~meta ~form : event list * string =
  let tree = Xml.parse xml in
  let root =
    match tree with
    | [] -> failwith "13D: empty document"
    | r :: _ -> r
  in
  let (filer_cik, make_event) = common root meta form in
  (* Per-person stakes. *)
  let persons =
    Xml.elems "reportingPersonInfo"
      (Xml.path [ "formData"; "reportingPersons" ] root
       |> Option.value ~default:(Xml.Text ""))
  in
  let events =
    List.map
      (fun p ->
        let person_cik =
          Xml.child_text "reportingPersonCIK" p
          |> Option.value ~default:""
          |> int_of_text
          |> Option.map (fun s -> Stringx.pad_left ~length:10 ~with_:'0' (string_of_int s))
          |> Option.value ~default:filer_cik
        in
        let filer_name =
          Xml.child_text "reportingPersonName" p |> Option.value ~default:""
        in
        make_event
          ~filer_cik:person_cik
          ~filer_name
          ~shares:(Xml.child_text "aggregateAmountOwned" p |> Option.value ~default:"" |> int_of_text)
          ~percent:(Xml.child_text "percentOfClass" p |> Option.value ~default:"" |> float_of_text)
          ~passive:false)
      persons
    |> (fun l ->
        if l = []
        then
          (* Fallback: no reportingPersons element — synthesise from the
             header filer so the filing is not lost. *)
          [ make_event ~filer_cik ~filer_name:"" ~shares:None ~percent:None ~passive:false ]
        else l)
  in
  (* Item prose: items1To7/itemN/{prose children}, skipping flags. *)
  let items =
    Xml.path [ "formData"; "items1To7" ] root
    |> Option.value ~default:(Xml.Text "")
  in
  let prose_of (item : Xml.node) (label : string) : string option =
    match item with
    | Xml.Elem e ->
      let texts =
        List.filter_map
          (fun c ->
            match c with
            | Xml.Elem ce
              when Xml.local_name ce.name <> "notApplicableFlag"
                && Xml.local_name ce.name <> "issuerPrincipalAddress" ->
              let t = Xml.text_of c in
              if t = "" then None else Some t
            | _ -> None)
          e.children
      in
      (match texts with
       | [] -> None
       | _ -> Some (label ^ "\n\n" ^ String.concat "\n\n" texts))
    | Xml.Text _ -> None
  in
  let item_labels =
    [
      ("item1", "Item 1 — security, explanatory note");
      ("item2", "Item 2 — person(s)");
      ("item3", "Item 3 — source and amount of funds");
      ("item4", "Item 4 — purpose of transaction");
      ("item5", "Item 5 — transaction or transactions");
      ("item6", "Item 6 — beneficial ownership");
      ("item7", "Item 7 — exhibits");
    ]
  in
  let parts =
    List.filter_map
      (fun (name, label) ->
        match Xml.elem name items with
        | Some item -> prose_of item label
        | None -> None)
      item_labels
    @ ( List.filter_map
          (fun p ->
            match Xml.child_text "commentContent" p with
            | Some s when s <> "" -> Some ("Person comment" ^ "\n\n" ^ s)
            | _ -> None)
          persons )
  in
  (events, String.concat "\n\n\n" parts)

(* ------------------------------------------------------------------ *)
(* 13F                                                                 *)
(* ------------------------------------------------------------------ *)

(** One position of the 13F information table. [issuer_cik] is resolved
    by the pipeline against the company-tickers file (name match); it is
    not present in the raw XML. *)
type position = {
  issuer_name : string;
  issuer_cusip : string;
  class_name : string;
  value_usd : int option;
  shares : int option;
  prnamt_type : string;
  (** SH / PRN / UNIT *)
  discretion : string;
  vote_sole : int option;
  vote_shared : int option;
  vote_none : int option;
}

type t13f = {
  filer_cik : string;
  filer_name : string;
  period : Date.t;
  is_amendment : bool;
  total_value_usd : int option;
  positions : position list;
}

(** [parse_13f cover_xml ~meta ~form table]: cover XML plus the raw
    information-table XML ([None] yields zero positions). *)
let parse_13f (cover_xml : string) ~meta ~form (table : string option) : t13f =
  let tree = Xml.parse cover_xml in
  let root =
    match tree with
    | [] -> failwith "13F: empty cover"
    | r :: _ -> r
  in
  let filer_cik =
    Xml.path_text [ "headerData"; "filerInfo"; "filer"; "credentials"; "cik" ] root
    |> Option.value ~default:"-1"
    |> int_of_text
    |> Option.value ~default:(-1)
    |> string_of_int
    |> Stringx.pad_left ~length:10 ~with_:'0'
  in
  let filer_name =
    Xml.path_text [ "formData"; "coverPage"; "filingManager"; "name" ] root
    |> Option.value ~default:""
  in
  let period =
    Xml.path_text [ "headerData"; "filerInfo"; "periodOfReport" ] root
    |> Option.value ~default:""
    |> of_sec_date
    |> Option.value ~default:meta.filed_at
  in
  let is_am =
    Xml.path_text [ "formData"; "coverPage"; "isAmendment" ] root
    |> Option.value ~default:"false"
    |> String.lowercase_ascii
    = "true"
    || is_amendment_of form
  in
  let total =
    Xml.path_text [ "formData"; "summaryPage"; "tableValueTotal" ] root
    |> Option.value ~default:""
    |> int_of_text
  in
  let positions =
    match table with
    | None -> []
    | Some t ->
      let ttree = Xml.parse t in
      (match ttree with
       | [] -> []
       | _ ->
         let rows =
           ttree |> List.map (fun r -> Xml.elems "infoTable" r) |> List.concat
         in
         List.map
           (fun row ->
             let vote =
               (match Xml.elem "votingAuthority" row with
                | Some v -> v
                | None -> Xml.Text "")
             in
             { issuer_name =
                 Xml.child_text "nameOfIssuer" row |> Option.value ~default:""
             ; issuer_cusip = Xml.child_text "cusip" row |> Option.value ~default:""
             ; class_name = Xml.child_text "titleOfClass" row |> Option.value ~default:""
             ; value_usd =
                 Xml.child_text "value" row |> Option.value ~default:"" |> int_of_text
             ; shares =
                 Xml.path_text [ "shrsOrPrnAmt"; "sshPrnamt" ] row
                 |> Option.value ~default:""
                 |> int_of_text
             ; prnamt_type =
                 Xml.path_text [ "shrsOrPrnAmt"; "sshPrnamtType" ] row
                 |> Option.value ~default:""
             ; discretion =
                 Xml.child_text "investmentDiscretion" row |> Option.value ~default:""
             ; vote_sole =
                 Xml.child_text "Sole" vote |> Option.value ~default:"" |> int_of_text
             ; vote_shared =
                 Xml.child_text "Shared" vote |> Option.value ~default:"" |> int_of_text
             ; vote_none =
                 Xml.child_text "None" vote |> Option.value ~default:"" |> int_of_text })
           rows)
  in
  { filer_cik
  ; filer_name
  ; period
  ; is_amendment = is_am
  ; total_value_usd = total
  ; positions }
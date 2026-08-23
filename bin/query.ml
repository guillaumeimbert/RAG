(** raguesslighter-query: search or ask questions over ingested SEC filings.

    Subcommands:
      search TEXT  vector search; prints the top hits with metadata;
      ask TEXT     vector search + a grounded LLM answer with citations;
                   ownership questions also get exact SQL-backed figures;
      holders --subject <TICKER|CIK>  structured ownership query (no LLM):
                   13G/13D significant holders + 13F institutional holders.
 *)

open Cmdliner

let run_query ~env_file (f : Config.t -> Store.t -> unit Lwt.t) : (unit, string) result =
  (try
     let cfg = Config.load ~env_file () in
     Lwt_main.run (Lwt.bind (Store.create cfg) (fun store -> Lwt.bind (f cfg store) (fun () -> Store.close store)));
     Ok ()
   with
   | Config.Missing k -> Error ("missing environment variable: " ^ k)
   | Edgar.Failure msg -> Error msg
   | Store.Db msg -> Error ("database: " ^ msg)
   | Openai.Api_error msg -> Error ("inference server: " ^ msg)
   | Net.Http_error e -> Error (Net.show_error e)
   | e -> Error (Printexc.to_string e))

let env_arg () =
  Arg.value
    (Arg.opt Arg.string ".env"
       (Arg.info ["e"; "env-file"] ~docv:"FILE" ~doc:"Path to the .env file."))

let top_k_arg () =
  Arg.value
    (Arg.opt (Arg.some' Arg.int) None
       (Arg.info ["k"; "top-k"] ~docv:"N"
          ~doc:"Number of hits (default: TOP_K from .env)."))

let cik_arg () =
  Arg.value
    (Arg.opt (Arg.some' Arg.string) None (Arg.info ["cik"] ~docv:"CIK" ~doc:"Restrict to one CIK."))

let form_arg () =
  Arg.value
    (Arg.opt (Arg.some' Arg.string) None (Arg.info ["form"] ~docv:"FORM" ~doc:"Restrict to one form (e.g. 10-K)."))

let ticker_arg () =
  Arg.value
    (Arg.opt (Arg.some' Arg.string) None (Arg.info ["ticker"] ~docv:"TICKER" ~doc:"Restrict to one ticker."))

(** Embed a query string into the store's vector format. *)
let embed_query (cfg : Config.t) (text : string) : string Lwt.t =
  Lwt.bind (Openai.embed ~cfg [ text ]) (function
    | [ v ] -> Lwt.return (Store.vector_to_string v)
    | _ -> Lwt.fail (Openai.Api_error "unexpected number of embeddings"))

let meta (h : Store.hit) : string =
  let ticker = if h.ticker = "" then "" else " (" ^ h.ticker ^ ")" in
  let section = if h.section = "" then "" else ", \"" ^ h.section ^ "\"" in
  h.company ^ ticker ^ " — " ^ h.form ^ ", filed " ^ h.filed_at ^ section

(** [truncate s n] = [s] cut to at most [n] bytes (≈ characters for ASCII
    text), suffixed with an ellipsis when shortened. The cut is backed off
    to a UTF-8 character boundary so a multi-byte character is never split
    (a dangling lead byte would make the LLM request body invalid UTF-8
    and the server reject it). *)
let truncate s n =
  if String.length s <= n
  then s
  else
    (* UTF-8 continuation bytes are 10xxxxxx; a cut point [i] is valid iff
       the byte at [i] starts a character (i.e. is not a continuation
       byte). Back off from [n] to the nearest such point. *)
    let is_cont c = (Char.code c land 0xC0) = 0x80 in
    let i = ref n in
    while !i > 0 && is_cont (String.get s !i) do decr i done;
    String.sub s 0 !i ^ " […]"

(* ------------------------------------------------------------------ *)
(* Structured ownership (SQL, not vectors)                            *)
(* ------------------------------------------------------------------ *)

let fmt_float (v : float) : string =
  if v < 0. then "not stated" else Printf.sprintf "%.0f" v

let fmt_percent (v : float) : string =
  if v < 0. then "not stated" else Printf.sprintf "%.2f%%" v

let is_cik s =
  s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s

let pad10 s = Stringx.pad_left s ~length:10 ~with_:'0'

(** Resolve a ticker, company name, or (unpadded) CIK to a 10-digit CIK. *)
let resolve_subject cfg (s : string) : string option Lwt.t =
  if is_cik s then Lwt.return (Some (pad10 s)) else Edgar.resolve cfg s

(** One 13G/13D holder row, with the delta against the previous event. *)
let holder_line (h : Store.holder) : string =
  let passive = if h.passive then ", passive" else "" in
  let prev =
    if h.prev_percent >= 0. || h.prev_shares >= 0.
    then " (prev event: " ^ fmt_percent h.prev_percent ^ ", " ^ fmt_float h.prev_shares ^ " sh)"
    else ""
  in
  Printf.sprintf "  %s (%s, event %s, filed %s%s): %s of %s — %s shares%s" h.filer_name h.form h.event_date h.filed_at passive (fmt_percent h.percent) (if h.class_name = "" then "common stock" else h.class_name) (fmt_float h.shares) prev

(** One 13F position row. *)
let position_line (p : Store.position) : string =
  let cls = if p.class_name = "" then "" else " (" ^ p.class_name ^ ")" in
  Printf.sprintf "  %s (period %s): $%s, %s shares%s" p.filer_name p.period (fmt_float p.value_usd) (fmt_float p.shares) cls

(** Words that cannot be a company in an ownership question. *)
let stop_words =
  let h = Hashtbl.create 96 in
  List.iter
    (fun w -> Hashtbl.replace h w ())
    [
      "A"; "AN"; "THE"; "AND"; "OR"; "OF"; "TO"; "IN"; "ON"; "FOR"; "WITH"; "ABOUT";
      "ANY"; "ALL"; "SOME"; "MANY"; "FEW"; "MORE"; "MOST"; "MUCH";
      "WHO"; "WHOM"; "WHOSE"; "WHICH"; "WHAT"; "WHEN"; "WHERE"; "WHY"; "HOW";
      "DOES"; "DO"; "DID"; "IS"; "ARE"; "WAS"; "WERE"; "BE"; "BEEN"; "BEING";
      "HAS"; "HAVE"; "HAD"; "HOLD"; "HOLDS"; "HELD"; "OWN"; "OWNS"; "OWNED";
      "OWNERSHIP"; "HOLDER"; "HOLDERS"; "SHAREHOLDER"; "SHAREHOLDERS";
      "STAKE"; "STAKES"; "STAKED"; "PORTFOLIO"; "INSTITUTIONAL"; "INSTITUTIONS";
      "MAJOR"; "SIGNIFICANT"; "TOP"; "LARGEST"; "BIGGEST"; "PERCENT";
      "PERCENTAGE"; "SHARE"; "SHARES"; "SECURITIES"; "POSITION"; "POSITIONS";
      "CORP"; "CORPORATION"; "INC"; "PLC"; "LLC"; "LP"; "LTD"; "SA"; "NV";
      "KG"; "GMBH"; "HOLDINGS"; "GROUP"; "COMPANY"; "CURRENTLY"; "RECENTLY";
      "NOW"; "TODAY"; "AS"; "AT"; "BY"; "FROM"; "BETWEEN"; "DURING"; "OVER";
      "UNDER"; "SINCE"; "AFTER"; "BEFORE"; "FILED"; "FILING"; "FILINGS";
      "SCHEDULE"; "REPORT"; "REPORTED"; "REPORTING"; "DISCLOSED"; "DISCLOSURE";
    ];
  h

(** Extract ticker/name candidates from a question: alphabetic words of
    length >= 2, upper-cased, de-duplicated, stopwords dropped, first [n]. *)
let extract_candidates (question : string) : string list =
  let s =
    question
    |> String.to_seq
    |> Seq.map (fun c ->
         if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') then c else ' ')
    |> String.of_seq
  in
  let seen = ref [] in
  s
  |> String.split_on_char ' '
  |> List.filter
       (fun w ->
         String.length w >= 2
         && not (String.for_all (fun c -> c >= '0' && c <= '9') w)
         && not (Hashtbl.mem stop_words (String.uppercase_ascii w)))
  |> List.map String.uppercase_ascii
  |> List.filter (fun w -> if List.mem w !seen then false else (seen := w :: !seen; true))
  |> List.take 8

(** [ownership_evidence cfg store question] = the structured (SQL)
    ownership block for the entities mentioned in [question], or "" when
    the question is not ownership-flavoured or nothing resolves. *)
let ownership_re =
  Re.compile
    (Re.Pcre.re
       "(holders?|ownership|stak(e|ed|es)|institutional|portfolio|13f|13d|13g|who (owns|holds)|percent)")

let ownership_evidence (cfg : Config.t) (store : Store.t) (question : string) : string Lwt.t =
  let is_ownership =
    Re.all ownership_re (String.lowercase_ascii question) <> []
  in
  if not is_ownership then Lwt.return ""
  else
    let candidates = extract_candidates question in
    let rec resolve_many acc (left : string list) : (string * string) list Lwt.t =
      match left with
      | [] -> Lwt.return (List.rev acc)
      | w :: tl ->
        Lwt.bind (Edgar.resolve cfg w) (function
          | None -> resolve_many acc tl
          | Some cik ->
            if List.exists (fun (_, c) -> c = cik) acc then resolve_many acc tl
            else if List.length acc >= 2 then resolve_many acc tl
            else resolve_many ((w, cik) :: acc) tl)
    in
    Lwt.bind (resolve_many [] candidates) (fun ents ->
      if ents = [] then Lwt.return ""
      else
        Lwt_list.fold_left_s
          (fun acc (word, cik) ->
            Lwt.bind (Store.holders_of store ~subject_cik:cik ~limit:5) (fun holders ->
              Lwt.bind (Store.positions_of store ~issuer_cik:cik ~issuer_name:"" ~limit:5) (fun positions ->
                let block =
                  if holders = [] && positions = []
                  then Printf.sprintf "%s (CIK %s): no ownership data ingested\n" word cik
                  else
                    let h =
                      if holders = []
                      then ""
                      else
                        "  13G/13D significant holders (latest event per filer):\n"
                        ^ String.concat "\n" (List.map holder_line holders)
                        ^ "\n"
                    in
                    let p =
                      if positions = []
                      then ""
                      else
                        "  13F institutional positions (latest report per filer):\n"
                        ^ String.concat "\n" (List.map position_line positions)
                        ^ "\n"
                    in
                    Printf.sprintf "%s (CIK %s):\n%s%s" word cik h p
                in
                Lwt.return (acc ^ block))))
          "" ents)

(* ------------------------------------------------------------------ *)
(* search                                                               *)
(* ------------------------------------------------------------------ *)

let search_cmd =
  let text =
    Arg.required
      (Arg.pos 0 (Arg.some' Arg.string) None (Arg.info [] ~docv:"TEXT" ~doc:"Text to search for."))
  in
  let k = top_k_arg () in
  let cik = cik_arg () in
  let form = form_arg () in
  let ticker = ticker_arg () in
  let env = env_arg () in
  let term =
    let open Term.Syntax in
    let+ text = text
    and+ k = k
    and+ cik = cik
    and+ form = form
    and+ ticker = ticker
    and+ e = env
    in
    run_query ~env_file:e (fun cfg store ->
        Lwt.bind (embed_query cfg text) (fun q ->
          Lwt.bind (Store.search store ~query:q ~top_k:(Option.value ~default:cfg.Config.top_k k) ~cik:cik ~form:form ~ticker:ticker ()) (fun hits ->
            if hits = []
            then Printf.printf "no results\n"
            else
              List.iteri
                (fun i (h : Store.hit) ->
                  Printf.printf "[%d] %.3f  %s\n     %s\n" (i + 1) h.similarity (meta h)
                    (truncate (Stringx.replace h.text ~sub:"\n" ~by:" ") 240);
                  ())
                hits;
            Lwt.return_unit)))
  in
  Cmd.v (Cmd.info "search" ~doc:"Vector search over ingested filings.") term

(* ------------------------------------------------------------------ *)
(* ask                                                                  *)
(* ------------------------------------------------------------------ *)

let system_prompt =
  "You answer questions strictly from the provided material: structured ownership "
  ^ "data (exact figures from SEC 13F/13G/13D filings) and/or excerpts from SEC "
  ^ "filings. Cite excerpts with [n] markers matching their numbers, and cite "
  ^ "figures from the structured ownership data as [SQL]. If the answer is not in "
  ^ "the material, say so plainly. Be concise and factual."

let ask_cmd =
  let text =
    Arg.required
      (Arg.pos 0 (Arg.some' Arg.string) None (Arg.info [] ~docv:"TEXT" ~doc:"Question to ask."))
  in
  let k = top_k_arg () in
  let cik = cik_arg () in
  let form = form_arg () in
  let ticker = ticker_arg () in
  let env = env_arg () in
  let term =
    let open Term.Syntax in
    let+ text = text
    and+ k = k
    and+ cik = cik
    and+ form = form
    and+ ticker = ticker
    and+ e = env
    in
    run_query ~env_file:e (fun cfg store ->
        Lwt.bind (embed_query cfg text) (fun q ->
          Lwt.bind (Store.search store ~query:q ~top_k:(Option.value ~default:cfg.Config.top_k k) ~cik:cik ~form:form ~ticker:ticker ()) (fun hits ->
            Lwt.bind (ownership_evidence cfg store text) (fun evidence ->
              if hits = [] && evidence = ""
              then (
                Printf.printf "no results\n";
                Lwt.return_unit)
              else
                let excerpts =
                  List.mapi
                    (fun i h ->
                      Format.sprintf "[%d] %s\n%s" (i + 1) (meta h)
                        (truncate h.text 900))
                    hits
                  in
                let evidence_block =
                  if evidence = "" then "" else "\n\nStructured ownership data (exact figures from SQL):\n" ^ evidence
                in
                let excerpts_block =
                  if hits = [] then "" else "\n\nExcerpts from SEC filings:\n\n" ^ String.concat "\n\n" excerpts
                in
                let user = "Question: " ^ text ^ evidence_block ^ excerpts_block in
                Lwt.bind
                  (Openai.chat ~cfg ~system:system_prompt
                     [ { Openai.role = `User; content = user } ])
                  (fun answer ->
                    Printf.printf "%s\n\nSources:\n" answer;
                    List.iteri
                      (fun i h -> Printf.printf "  [%d] %s\n" (i + 1) (meta h))
                      hits;
                    (if evidence = "" then ()
                     else Printf.printf "  [SQL] structured ownership data (13F/13G/13D, exact figures)\n");
                    Lwt.return_unit)))))
  in
  Cmd.v (Cmd.info "ask" ~doc:"Grounded question answering over ingested filings.") term

(* ------------------------------------------------------------------ *)
(* holders                                                            *)
(* ------------------------------------------------------------------ *)

let holders_cmd =
  let subject =
    Arg.value
      (Arg.opt (Arg.some' Arg.string) None
         (Arg.info [ "subject"; "s" ] ~docv:"TICKER|CIK"
            ~doc:"Subject company (ticker, name, or CIK)."))
  in
  let limit =
    Arg.value
      (Arg.opt Arg.int 10
         (Arg.info [ "l"; "limit" ] ~docv:"N" ~doc:"Max rows per section."))
  in
  let env = env_arg () in
  let term =
    let open Term.Syntax in
    let+ s = subject
    and+ l = limit
    and+ e = env
    in
    run_query ~env_file:e (fun cfg store ->
      match s with
      | None -> raise (Edgar.Failure "holders requires --subject <TICKER|CIK>")
      | Some subj ->
        Lwt.bind (resolve_subject cfg subj) (function
          | None ->
            Printf.printf "could not resolve %s to a CIK\n%!" subj;
            Lwt.return_unit
          | Some cik ->
            Lwt.bind (Store.holders_of store ~subject_cik:cik ~limit:l) (fun holders ->
              Lwt.bind (Store.positions_of store ~issuer_cik:cik ~issuer_name:"" ~limit:l) (fun positions ->
                Printf.printf "Ownership of %s (CIK %s), from ingested 13G/13D/13F filings:\n%!
" subj cik;
                (if holders = []
                 then Printf.printf "  (no 13G/13D events ingested)\n%!"
                 else
                   (Printf.printf "  13G/13D significant holders (latest event per filer):\n%!";
                    List.iter (fun (h : Store.holder) -> Printf.printf "%s\n%!" (holder_line h)) holders));
                (if positions = []
                 then Printf.printf "  (no 13F positions ingested)\n%!"
                 else
                   (Printf.printf "  13F institutional positions (latest report per filer):\n%!";
                    List.iter (fun (p : Store.position) -> Printf.printf "%s\n%!" (position_line p)) positions));
                Lwt.return_unit))))
  in
  Cmd.v
    (Cmd.info "holders"
       ~doc:"Structured ownership query: 13G/13D holders + 13F positions of a company (SQL, no LLM).")
    term

(* ------------------------------------------------------------------ *)

let main =
  Cmd.group (Cmd.info "query" ~doc:"Search and query ingested SEC filings.")
    [ search_cmd; ask_cmd; holders_cmd ]

let () =
  let code = Cmd.eval_result main in
  if code <> 0 then exit code
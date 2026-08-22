(** raguesslighter-query: search or ask questions over ingested SEC filings.

    Subcommands:
      search TEXT  vector search; prints the top hits with metadata;
      ask TEXT     vector search + a grounded LLM answer with citations.
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

let truncate s n =
  if String.length s <= n then s else String.sub s 0 n ^ " […]"

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
  "You answer questions strictly from the provided excerpts from SEC filings. "
  ^ "Cite excerpts with [n] markers matching their numbers. If the answer is "
  ^ "not in the excerpts, say so plainly. Be concise and factual."

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
            if hits = []
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
              let user =
                "Question: " ^ text
                ^ "\n\nExcerpts from SEC filings:\n\n"
                ^ String.concat "\n\n" excerpts
              in
              Lwt.bind
                (Openai.chat ~cfg ~system:system_prompt
                   [ { Openai.role = `User; content = user } ])
                (fun answer ->
                  Printf.printf "%s\n\nSources:\n" answer;
                  List.iteri
                    (fun i h -> Printf.printf "  [%d] %s\n" (i + 1) (meta h))
                    hits;
                  Lwt.return_unit))))
  in
  Cmd.v (Cmd.info "ask" ~doc:"Grounded question answering over ingested filings.") term

(* ------------------------------------------------------------------ *)

let main =
  Cmd.group (Cmd.info "query" ~doc:"Search and query ingested SEC filings.")
    [ search_cmd; ask_cmd ]

let () =
  let code = Cmd.eval_result main in
  if code <> 0 then exit code
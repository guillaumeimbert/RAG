(** raguesslighter-ingest: pull SEC EDGAR filings into the vector store.

    Subcommands:
      day DATE       one business day (discovery via daily-index sitemaps)
      backfill ...   a range of days; weekends and holidays are skipped
      cik CIK        the recent filing history of one company
      ticker TICKER  same as cik, resolved via company-tickers.json
      stats          current store contents
 *)

open Cmdliner

(** Run a job under a fresh store connection, translating failures into
    [Error] strings for cmdliner. *)
let run_job ~env_file (f : Store.t -> Config.t -> unit Lwt.t) : (unit, string) result =
  (try
     let cfg = Config.load ~env_file () in
     Lwt_main.run
       ( Lwt.bind (Store.create cfg) (fun store ->
           Lwt.bind (f store cfg) (fun () -> Store.close store)) );
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

let parse_date s =
  (try Date.of_string s
   with Failure _ -> raise (Edgar.Failure (s ^ ": invalid date (expected YYYY-MM-DD)")))

(* ------------------------------------------------------------------ *)
(* day                                                                  *)
(* ------------------------------------------------------------------ *)

(** Non-zero exit when some filings failed (embedding/DB): the run did
    not complete cleanly even though no partial state was left behind
    (writes are transactional) — a re-run retries the failed filings. *)
let finish (s : Pipeline.stats) : unit Lwt.t =
  if s.Pipeline.failed > 0
  then
    Lwt.fail
      (Edgar.Failure
         (Printf.sprintf
            "failed=%d — run did not complete cleanly (nothing partial was stored); re-run to retry the failed filings"
            s.Pipeline.failed))
  else Lwt.return_unit

let day_cmd =
  let date =
    Arg.required
      (Arg.pos 0 (Arg.some' Arg.string) None
         (Arg.info [] ~docv:"DATE" ~doc:"Filing date to ingest (YYYY-MM-DD)."))
  in
  let env = env_arg () in
  let term =
    let open Term.Syntax in
    let+ d = date
    and+ e = env
    in
    run_job ~env_file:e (fun store _cfg ->
        let d = parse_date d in
        Lwt.bind (Pipeline.ingest_day store d) (fun s ->
          Printf.printf "%s  %s\n" (Date.to_string d) (Pipeline.show_stats s);
          finish s))
  in
  Cmd.v (Cmd.info "day" ~doc:"Ingest all matching filings for one business day.") term

(* ------------------------------------------------------------------ *)
(* backfill                                                             *)
(* ------------------------------------------------------------------ *)

let backfill_cmd =
  let from =
    Arg.value
      (Arg.opt (Arg.some' Arg.string) None
         (Arg.info ["from"] ~docv:"DATE" ~doc:"First date, inclusive (YYYY-MM-DD)."))
  in
  let to_ =
    Arg.value
      (Arg.opt (Arg.some' Arg.string) None
         (Arg.info ["to"] ~docv:"DATE" ~doc:"Last date, inclusive (YYYY-MM-DD)."))
  in
  let env = env_arg () in
  let term =
    let open Term.Syntax in
    let+ f = from
    and+ t = to_
    and+ e = env
    in
    run_job ~env_file:e (fun store _cfg ->
        match (f, t) with
        | Some f, Some t ->
          Lwt.bind (Pipeline.ingest_range store (parse_date f) (parse_date t)) (fun s ->
            Printf.printf "total  %s\n" (Pipeline.show_stats s);
            finish s)
        | _ -> raise (Edgar.Failure "backfill requires both --from and --to"))
  in
  Cmd.v
    (Cmd.info "backfill" ~doc:"Ingest a range of business days (weekends/holidays skipped).")
    term

(* ------------------------------------------------------------------ *)
(* cik / ticker                                                         *)
(* ------------------------------------------------------------------ *)

let cik_cmd =
  let cik =
    Arg.required
      (Arg.pos 0 (Arg.some' Arg.string) None
         (Arg.info [] ~docv:"CIK" ~doc:"Company CIK (e.g. 320193)."))
  in
  let env = env_arg () in
  let limit =
    Arg.value
      (Arg.opt Arg.int 0
         (Arg.info [ "l"; "limit" ] ~docv:"N"
            ~doc:"Ingest at most the N most recent filings (default: all)."))
  in
  let term =
    let open Term.Syntax in
    let+ c = cik
    and+ e = env
    and+ l = limit
    in
    run_job ~env_file:e (fun store _cfg ->
        let limit = if l > 0 then Some l else None in
        Lwt.bind (Pipeline.ingest_cik ?limit store c) (fun s ->
          Printf.printf "CIK %s  %s\n" c (Pipeline.show_stats s);
          finish s))
  in
  Cmd.v (Cmd.info "cik" ~doc:"Ingest the recent filings of one company (by CIK).") term

let ticker_cmd =
  let ticker =
    Arg.required
      (Arg.pos 0 (Arg.some' Arg.string) None
         (Arg.info [] ~docv:"TICKER" ~doc:"Ticker (e.g. AAPL)."))
  in
  let env = env_arg () in
  let limit =
    Arg.value
      (Arg.opt Arg.int 0
         (Arg.info [ "l"; "limit" ] ~docv:"N"
            ~doc:"Ingest at most the N most recent filings (default: all)."))
  in
  let term =
    let open Term.Syntax in
    let+ t = ticker
    and+ e = env
    and+ l = limit
    in
    run_job ~env_file:e (fun store cfg ->
        let limit = if l > 0 then Some l else None in
        Lwt.bind (Edgar.cik_of_ticker cfg t) (function
          | None -> raise (Edgar.Failure ("unknown ticker: " ^ t))
          | Some cik ->
            Lwt.bind (Pipeline.ingest_cik ?limit store cik) (fun s ->
              Printf.printf "%s (CIK %s)  %s\n" t cik (Pipeline.show_stats s);
              finish s)))
  in
  Cmd.v (Cmd.info "ticker" ~doc:"Ingest the recent filings of one company (by ticker).")
    term

(* ------------------------------------------------------------------ *)
(* stats                                                                *)
(* ------------------------------------------------------------------ *)

let stats_cmd =
  let env = env_arg () in
  let term =
    let open Term.Syntax in
    let+ e = env
    in
    run_job ~env_file:e (fun store _cfg ->
        Lwt.bind (Store.stats store) (fun s ->
          Printf.printf "documents:        %d\n" s.Store.docs;
          Printf.printf "chunks:           %d\n" s.Store.chunks;
          Printf.printf "ownership events: %d\n" s.Store.ownership_events;
          Printf.printf "13F positions:    %d\n" s.Store.holdings;
          Lwt.return_unit))
  in
  Cmd.v (Cmd.info "stats" ~doc:"Show the current contents of the store.") term

(* ------------------------------------------------------------------ *)

let main =
  Cmd.group
    (Cmd.info "ingest" ~doc:"Ingest SEC EDGAR filings into the vector store.")
    [ day_cmd; backfill_cmd; cik_cmd; ticker_cmd; stats_cmd ]

let () =
  let code = Cmd.eval_result main in
  if code <> 0 then exit code
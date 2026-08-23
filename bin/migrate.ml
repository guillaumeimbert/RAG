(** raguesslighter-migrate: apply the schema migrations.

    Subcommands:
      up       apply the missing migrations (in order, transactionally, under
               an advisory lock);
      status   report the applied and pending migrations (no changes).

    A database created before the schema_migrations tracker existed (schema
    present, no records) is brought up to date by `up`: the migrations are
    idempotent and corrective, so re-running them converges the schema to the
    current definitions before the checksums are recorded.

    The numbered files under schema/ are immutable once applied: never edit
    one that has been recorded; add a new NNNN_<name>.sql instead.
 *)

open Cmdliner

(** Run a migration command. Only the database URL is loaded (the migration
    tool does not need the inference/SEC/chunking configuration). *)
let run_migrate ~env_file (f : string -> (string, string) result Lwt.t) : (unit, string) result =
  (try
     let url = Config.load_database_url ~env_file () in
     Lwt_main.run
       ( Lwt.bind (f url) (function
         | Ok summary -> (Printf.printf "%s\n" summary; Lwt.return_unit)
         | Error msg -> Lwt.fail (Failure msg)) );
     Ok ()
   with
   | Config.Missing k -> Error ("missing environment variable: " ^ k)
   | Failure msg -> Error msg
   | e -> Error (Printexc.to_string e))

let env_arg () =
  Arg.value
    (Arg.opt Arg.string ".env"
       (Arg.info ["e"; "env-file"] ~docv:"FILE" ~doc:"Path to the .env file."))

let up_cmd =
  let env = env_arg () in
  let term =
    let open Term.Syntax in
    let+ e = env in run_migrate ~env_file:e (fun url -> Migration.up url)
  in
  Cmd.v (Cmd.info "up" ~doc:"Apply the missing migrations (transactionally, under an advisory lock).") term

let status_cmd =
  let env = env_arg () in
  let term =
    let open Term.Syntax in
    let+ e = env in run_migrate ~env_file:e (fun url -> Migration.status url)
  in
  Cmd.v (Cmd.info "status" ~doc:"Report the applied and pending migrations (no changes).") term

let main =
  Cmd.group (Cmd.info "migrate" ~doc:"Apply the schema migrations.") [ up_cmd; status_cmd ]

let () =
  let code = Cmd.eval_result main in
  if code <> 0 then exit code
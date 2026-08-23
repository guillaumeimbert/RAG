(** raguesslighter-migrate: apply the schema migrations.

    Subcommands:
      up       apply the missing migrations (in order, transactionally, under
               an advisory lock);
      status   report the applied and pending migrations (no changes);
      baseline record the current migrations as applied without re-running
               them (one-time transition for databases created before the
               schema_migrations tracker existed, e.g. by compose initdb).

    The numbered files under schema/ are immutable once applied: never edit
    one that has been recorded; add a new NNNN_<name>.sql instead.
 *)

open Cmdliner

let run_migrate ~env_file (f : Config.t -> (string, string) result Lwt.t) : (unit, string) result =
  (try
     let cfg = Config.load ~env_file () in
     Lwt_main.run
       ( Lwt.bind (f cfg) (function
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
    let+ e = env in run_migrate ~env_file:e (fun cfg -> Migration.up cfg)
  in
  Cmd.v (Cmd.info "up" ~doc:"Apply the missing migrations (transactionally, under an advisory lock).") term

let status_cmd =
  let env = env_arg () in
  let term =
    let open Term.Syntax in
    let+ e = env in run_migrate ~env_file:e (fun cfg -> Migration.status cfg)
  in
  Cmd.v (Cmd.info "status" ~doc:"Report the applied and pending migrations (no changes).") term

let baseline_cmd =
  let env = env_arg () in
  let term =
    let open Term.Syntax in
    let+ e = env in run_migrate ~env_file:e (fun cfg -> Migration.baseline cfg)
  in
  Cmd.v
    (Cmd.info "baseline"
       ~doc:"Record the current migrations as applied without re-running them (one-time transition).")
    term

let main =
  Cmd.group (Cmd.info "migrate" ~doc:"Apply the schema migrations.") [ up_cmd; status_cmd; baseline_cmd ]

let () =
  let code = Cmd.eval_result main in
  if code <> 0 then exit code
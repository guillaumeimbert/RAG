(** Schema migrations.

    The numbered files under [schema/] ([0001_init.sql], [0002_...sql], ...)
    are immutable once applied: never edit one that has been recorded; add a
    new [NNNN_<name>.sql] instead. Immutability is enforced at runtime — each
    applied file is recorded in the [schema_migrations] table with a SHA-256
    checksum of its contents, and a mismatch on a later run is a hard error.

    Migrations are applied by [bin/migrate.exe up] (a deployment step, not
    part of [Store.create]):

    - a PostgreSQL advisory lock serializes concurrent migrations;
    - each migration runs in a single transaction (its SQL statements and the
      [schema_migrations] record commit or roll back together);
    - migrations are applied in ascending version order, skipping those
      already recorded.

    The numbered files were previously applied by compose's
    [docker-entrypoint-initdb.d] (which left no record). A database created
    before the tracker existed (the schema present but with no
    [schema_migrations] records) is brought up to date by [up]: the migrations
    are idempotent and corrective, so re-running them converges the schema to
    the current definitions before the checksums are recorded. There is no
    separate "record without re-running" command, because re-running is safe
    and guarantees the converged definitions match the recorded checksums.
*)

(* ------------------------------------------------------------------ *)
(* Migration files                                                    *)
(* ------------------------------------------------------------------ *)

type migration = {
  version : int;
  name : string;
  path : string;
}

(** The directory containing the numbered migration files (relative to the
    working directory; the binaries are run from the project root). *)
let schema_dir = "schema"

(** List the migration files in [dir] (ascending version order). A migration
    file is named [NNNN_<name>.sql] (a four-digit version). Returns an
    [Error] on duplicate versions. *)
let migration_files (dir : string) : (migration list, string) result =
  let parse name =
    let n = String.length name in
    if n >= 9
       && String.get name 4 = '_'
       && String.ends_with name ~suffix:".sql"
       && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub name 0 4) then
      let version = int_of_string (String.sub name 0 4) in
      Some { version; name; path = Filename.concat dir name }
    else None
  in
  let migs =
    Sys.readdir dir
    |> Array.to_list
    |> List.filter_map parse
    |> List.sort (fun a b -> Int.compare a.version b.version)
  in
  let seen = Hashtbl.create 8 in
  let dup = ref (-1) in
  List.iter
    (fun m ->
      if Hashtbl.mem seen m.version then dup := m.version
      else Hashtbl.add seen m.version true)
    migs;
  (match !dup with
  | -1 -> Ok migs
  | v -> Error ("duplicate migration version " ^ string_of_int v ^ " in " ^ dir))

(* ------------------------------------------------------------------ *)
(* Checksums                                                          *)
(* ------------------------------------------------------------------ *)

(** The SHA-256 checksum (hex) of the file at [path]. *)
let checksum (path : string) : string = Sha256.to_hex (Sha256.file path)

(* ------------------------------------------------------------------ *)
(* SQL statement splitting                                            *)
(* ------------------------------------------------------------------ *)

(** Split a SQL script into top-level statements. A statement ends at a
    top-level semicolon (one not inside a string, a dollar-quoted body, or a
    comment). Dollar-quoted bodies ($$...$$ or $tag$...$tag$) may contain any
    text including ';' and are kept intact. Caqti's extended protocol rejects
    multi-statement prepared statements, so a migration file is executed
    statement-by-statement; each DO block is a single statement and is
    therefore handled correctly. *)
let split_statements (sql : string) : string list =
  let n = String.length sql in
  let i = ref 0 in
  let in_sq = ref false in (* inside '...' *)
  let in_lc = ref false in (* inside a -- line comment *)
  let in_bc = ref false in (* inside a /* ... */ block comment *)
  let in_dq = ref false in (* inside a $tag$ ... $tag$ body *)
  let dq_tag = ref "" in
  let buf = Buffer.create 1024 in
  let acc = ref [] in
  let flush () =
    let s = String.trim (Buffer.contents buf) in
    if s <> "" then acc := s :: !acc;
    Buffer.reset buf
  in
  let is_ident c =
    ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9') || c = '_'
  in
  while !i < n do
    let c = String.get sql !i in
    if !in_lc then (
      Buffer.add_char buf c;
      i := !i + 1;
      if c = '\n' then in_lc := false
    ) else if !in_bc then
      if c = '*' && !i + 1 < n && String.get sql (!i + 1) = '/' then (
        Buffer.add_string buf "*/";
        i := !i + 2;
        in_bc := false
      )
      else (Buffer.add_char buf c; i := !i + 1)
    else if !in_dq then
      if String.length sql - !i >= String.length !dq_tag
         && String.sub sql !i (String.length !dq_tag) = !dq_tag then (
        Buffer.add_string buf !dq_tag;
        i := !i + String.length !dq_tag;
        in_dq := false
      )
      else (Buffer.add_char buf c; i := !i + 1)
    else if !in_sq then
      if c = '\'' then
        if !i + 1 < n && String.get sql (!i + 1) = '\'' then
          (Buffer.add_string buf "''"; i := !i + 2)
        else (Buffer.add_char buf c; i := !i + 1; in_sq := false)
      else (Buffer.add_char buf c; i := !i + 1)
    else
      if c = '\'' then (in_sq := true; Buffer.add_char buf c; i := !i + 1)
      else if c = '-' && !i + 1 < n && String.get sql (!i + 1) = '-' then
        (in_lc := true; Buffer.add_char buf c; i := !i + 1)
      else if c = '/' && !i + 1 < n && String.get sql (!i + 1) = '*' then
        (in_bc := true; Buffer.add_char buf c; i := !i + 1)
      else if c = '$' then (
        let j = !i + 1 in
        (* a dollar-quote tag is $$ (empty) or $[A-Za-z_][A-Za-z0-9_]*$ *)
        let k =
          if j < n && String.get sql j = '$' then j
          else
            (let f = if j < n then String.get sql j else ' ' in
             if f = '_' || (f >= 'a' && f <= 'z') || (f >= 'A' && f <= 'Z') then
               (let kk = ref (j + 1) in
                while !kk < n && is_ident (String.get sql !kk) do
                  kk := !kk + 1
                done;
                if !kk < n && String.get sql !kk = '$' then !kk else -1)
             else -1)
        in
        if k >= 0 then (
          let tag = String.sub sql !i (k - !i + 1) in
          in_dq := true;
          dq_tag := tag;
          Buffer.add_string buf tag;
          i := k + 1
        )
        else (Buffer.add_char buf c; i := !i + 1)
      )
      else if c = ';' then (flush (); i := !i + 1)
      else (Buffer.add_char buf c; i := !i + 1)
  done;
  flush ();
  List.rev !acc

(* ------------------------------------------------------------------ *)
(* Database access                                                    *)
(* ------------------------------------------------------------------ *)

(** The [schema_migrations] table (created idempotently). [version] is the
    leading integer of the file name; [checksum] is the SHA-256 of the file's
    contents (the immutability guard); [applied_at] is the application time. *)
let migrations_table_sql =
  "CREATE TABLE IF NOT EXISTS schema_migrations ("
  ^ "version INT PRIMARY KEY, "
  ^ "checksum TEXT NOT NULL, "
  ^ "applied_at TIMESTAMPTZ NOT NULL DEFAULT now())"

(** A parameterless exec request built at runtime (the SQL is dynamic — a
    migration statement or a lock command). Built with [of_string_exn] so a
    malformed statement fails at build time rather than at exec time. *)
let exec_dyn (sql : string) =
  let open Caqti_request.Infix in
  let open Caqti_type.Std in
  (->.) unit unit sql

(** Run the dynamic statement [sql] on [conn], returning [Error] on failure
    (a malformed statement or a database error). *)
let exec_report (conn : Caqti_lwt.connection) (sql : string) : (unit, string) result Lwt.t =
  (match (try Ok (exec_dyn sql) with e -> Error (Printexc.to_string e)) with
  | Error msg -> Lwt.return (Error msg)
  | Ok req ->
    let module C = (val conn : Caqti_lwt.CONNECTION) in
    Lwt.catch
      (fun () ->
        Lwt.bind (C.exec req ()) (function
          | Ok _ -> Lwt.return (Ok ())
          | Error e -> Lwt.return (Error (Caqti_error.show e))))
      (fun e -> Lwt.return (Error (Printexc.to_string e))))

(** Acquire the advisory lock. [pg_advisory_lock] returns a value, so it is
    called via [PERFORM] inside a [DO] block (which returns nothing); the
    [exec] protocol can then run it. The lock is released when the connection
    closes. [pg_advisory_lock] blocks until the lock is available, so
    concurrent [up] runs are serialized. *)
let lock_sql =
  "DO $$ BEGIN PERFORM pg_advisory_lock(hashtext('raguesslighter_schema_migrations')); END $$;"

(** Record an applied migration (version, checksum). *)
let record_q =
  [%rapper
    execute
    {sql| INSERT INTO schema_migrations (version, checksum)
          VALUES (%int{version}, %string{checksum}) |sql}
    syntax_off]

(** The applied migrations (version, checksum) in ascending order. *)
let applied_q =
  [%rapper
    get_many
    {sql| SELECT version AS @int{version}, checksum AS @string{checksum}
          FROM schema_migrations ORDER BY version |sql}]

(** Read the contents of the migration file at [path]. *)
let read_file (path : string) : string =
  let ic = open_in path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

(** Apply a single migration ([m]) on [conn] in one transaction: the
    migration's statements and its [schema_migrations] record commit or roll
    back together. The [schema_migrations] table must already exist. *)
let apply_one (conn : Caqti_lwt.connection) (m : migration) : (unit, string) result Lwt.t =
  let stmts =
    (try Ok (split_statements (read_file m.path))
     with e -> Error ("cannot read " ^ m.name ^ ": " ^ Printexc.to_string e))
  in
  (match stmts with
  | Error msg -> Lwt.return (Error msg)
  | Ok stmts ->
    let cs = checksum m.path in
    let body () : (unit, string) result Lwt.t =
      Lwt.bind
        ( Lwt_list.fold_left_s
            (fun acc stmt ->
              (* short-circuit on the first failure so the original error is
                 preserved (a later statement would otherwise report "the
                 current transaction is aborted"). *)
              (match acc with
              | Error _ -> Lwt.return acc
              | Ok () ->
                Lwt.bind (exec_report conn stmt) (function
                  | Error msg -> Lwt.return (Error (msg ^ " (in " ^ m.name ^ ")"))
                  | Ok () -> Lwt.return (Ok ()))))
            (Ok ()) stmts )
        (function
        | Error msg -> Lwt.return (Error msg)
        | Ok () ->
        Lwt.catch
          (fun () ->
            Lwt.bind (record_q ~version:m.version ~checksum:cs conn) (function
              | Ok _ -> Lwt.return (Ok ())
              | Error e ->
                Lwt.return (Error ("record " ^ m.name ^ ": " ^ Caqti_error.show e))))
          (fun e -> Lwt.return (Error (Printexc.to_string e)))
        )
    in
    let rollback_then (err : string) : (unit, string) result Lwt.t =
      Lwt.bind (exec_report conn "ROLLBACK") (fun _ -> Lwt.return (Error err))
    in
    Lwt.catch
      (fun () ->
        Lwt.bind (exec_report conn "BEGIN") (function
          | Error msg -> Lwt.return (Error msg)
          | Ok () ->
            Lwt.catch
              (fun () ->
                Lwt.bind (body ()) (function
                  | Error msg -> rollback_then msg
                  | Ok () ->
                    Lwt.bind (exec_report conn "COMMIT") (function
                      | Ok () -> Lwt.return (Ok ())
                      | Error msg -> Lwt.return (Error msg))))
              (fun e -> rollback_then (Printexc.to_string e))))
      (fun e -> Lwt.return (Error (Printexc.to_string e))))

(** Open a dedicated connection (outside the pool), run [f] on it, and close
    the connection on every path. The advisory lock and the
    [schema_migrations] table are set up before [f] runs. The advisory lock is
    held until the connection closes. *)
let with_db (url : string) (f : Caqti_lwt.connection -> (string, string) result Lwt.t)
    : (string, string) result Lwt.t =
  Lwt.catch
    (fun () ->
      Lwt.bind (Caqti_lwt_unix.connect (Uri.of_string url)) (function
        | Error e -> Lwt.return (Error ("connect: " ^ Caqti_error.show e))
        | Ok conn ->
          let module C = (val conn : Caqti_lwt.CONNECTION) in
          Lwt.finalize
            (fun () ->
              Lwt.bind (exec_report conn lock_sql) (function
                | Error msg -> Lwt.return (Error ("acquire lock: " ^ msg))
                | Ok () ->
                  Lwt.bind (exec_report conn migrations_table_sql) (function
                    | Error msg -> Lwt.return (Error ("create schema_migrations: " ^ msg))
                    | Ok () -> f conn)))
            (fun () -> C.disconnect ())))
    (fun e -> Lwt.return (Error (Printexc.to_string e)))

(** Load the applied migrations (version, checksum) in ascending order. *)
let applied_map (conn : Caqti_lwt.connection) : ((int * string) list, string) result Lwt.t =
  Lwt.catch
    (fun () ->
      Lwt.bind (applied_q () conn) (function
        | Ok rows -> Lwt.return (Ok rows)
        | Error e -> Lwt.return (Error (Caqti_error.show e))))
    (fun e -> Lwt.return (Error (Printexc.to_string e)))

(* ------------------------------------------------------------------ *)
(* Commands                                                           *)
(* ------------------------------------------------------------------ *)

(** Verify the checksum of every recorded migration that still has a file
    (the immutability guard). Stops on the first mismatch. A record with no
    file is tolerated here (the [validate_history] check is the primary guard
    against a missing file). *)
let verify_checksums (migs : migration list) (applied : (int * string) list)
    : (unit, string) result Lwt.t =
  Lwt_list.fold_left_s
    (fun acc (v, cs) ->
      (match acc with
      | Error _ -> Lwt.return acc
      | Ok () ->
        (match List.find_opt (fun m -> m.version = v) migs with
        | Some m ->
          let cs_now = checksum m.path in
          if cs_now <> cs then
            Lwt.return
              (Error
                ("migration " ^ m.name ^ " changed after being applied (recorded " ^ cs
                 ^ ", current " ^ cs_now ^ "); never edit an applied migration — add a new file instead"))
          else Lwt.return (Ok ())
        | None -> Lwt.return (Ok ())
      )))
    (Ok ()) applied

(** The core history validation: the applied versions must be exactly the
    first [k] local versions (no gaps, no unknown versions, no missing files).
    Exposed for testing. *)
let validate_history_versions (local : int list) (applied : int list)
    : (unit, string) result =
  let applied_versions = List.sort Int.compare applied in
  let show_versions vs = "[" ^ String.concat ", " (List.map string_of_int vs) ^ "]" in
  let k = List.length applied_versions in
  if k > List.length local then
    Error ("migration history is inconsistent: " ^ string_of_int k
           ^ " applied but only " ^ string_of_int (List.length local)
           ^ " migration file(s) present")
  else
    let prefix = List.init k (fun i -> List.nth local i) in
    (if applied_versions = prefix then Ok ()
     else Error ("migration history is inconsistent: applied " ^ show_versions applied_versions
                 ^ " but expected the prefix " ^ show_versions prefix
                 ^ "; applied migrations must be a contiguous prefix of the available files"))

(** Check that the applied history is a valid prefix of the available
    migrations: every recorded version must be a local file version, and the
    recorded set must be exactly the first [k] local versions (no gaps, no
    unknown versions, no missing files). A history that is not a valid prefix
    (e.g. 0001 and 0003 recorded but not 0002, or a recorded version with no
    file) is an error. *)
let validate_history (migs : migration list) (applied : (int * string) list)
    : (unit, string) result =
  let local_versions = List.map (fun m -> m.version) migs in
  let applied_versions = List.map fst applied in
  validate_history_versions local_versions applied_versions

(** The migrations not yet recorded (in ascending order). *)
let pending_of (migs : migration list) (applied : (int * string) list) : migration list =
  let applied_versions = List.map fst applied in
  List.filter (fun m -> not (List.mem m.version applied_versions)) migs

(** Apply a list of migrations (in order), returning a one-line-per-file
    summary. *)
let apply_list (conn : Caqti_lwt.connection) (migs : migration list)
    : (string, string) result Lwt.t =
  let rec go (acc : string) = function
    | [] -> Lwt.return (Ok (String.trim acc))
    | m :: rest ->
      Lwt.bind (apply_one conn m) (function
        | Error msg -> Lwt.return (Error msg)
        | Ok () -> go (acc ^ "applied " ^ m.name ^ "\n") rest)
  in
  go "" migs

(** Apply the missing migrations (in ascending order). Returns a human-readable
    summary (the applied files, or "already up to date"). The applied history
    must be a valid prefix of the available files, and every recorded
    migration's checksum is verified against its file (immutability guard); a
    mismatch or an inconsistent history is an error. *)
let up (url : string) : (string, string) result Lwt.t =
  (match migration_files schema_dir with
  | Error msg -> Lwt.return (Error msg)
  | Ok migs ->
    with_db url (fun conn ->
      Lwt.bind (applied_map conn) (function
        | Error msg -> Lwt.return (Error msg)
        | Ok applied ->
          (match validate_history migs applied with
          | Error msg -> Lwt.return (Error msg)
          | Ok () ->
            Lwt.bind (verify_checksums migs applied) (function
              | Error msg -> Lwt.return (Error msg)
              | Ok () ->
                let pending = pending_of migs applied in
                (match pending with
                | [] -> Lwt.return (Ok "database is up to date (no migrations to apply)")
                | _ ->
                  apply_list conn pending
                  |> Lwt.map (function
                       | Ok s -> Ok (s ^ " — database is up to date")
                       | Error e -> Error e)))))))

(** Truncate a string to [n] characters (for the status display). *)
let short (s : string) (n : int) : string =
  if String.length s > n then String.sub s 0 n ^ "…" else s

(** Report the applied and pending migrations (no changes). Refuses an
    inconsistent applied history (a gap, an unknown version, or a missing
    file) rather than guessing. *)
let status (url : string) : (string, string) result Lwt.t =
  (match migration_files schema_dir with
  | Error msg -> Lwt.return (Error msg)
  | Ok migs ->
    with_db url (fun conn ->
      Lwt.bind (applied_map conn) (function
        | Error msg -> Lwt.return (Error msg)
        | Ok applied ->
          (match validate_history migs applied with
          | Error msg -> Lwt.return (Error msg)
          | Ok () ->
            let pending = pending_of migs applied in
            let lines =
              List.map (fun (v, cs) -> Printf.sprintf "applied  %4d  %s" v (short cs 12)) applied
              @ List.map (fun m -> Printf.sprintf "pending  %4d  %s" m.version m.name) pending
            in
            Lwt.return
              (Ok
                (String.concat "\n" lines
                 ^ Printf.sprintf "\n%d applied, %d pending" (List.length applied) (List.length pending)))))))

(** Apply the migrations with [version < upto] (a prefix of the migration
    list), recording each. Opens its own connection and takes the advisory
    lock (and creates the [schema_migrations] table). Used to create an "old
    schema snapshot" and to test the upgrade path. *)
let snapshot_up_to (url : string) (upto : int) : (string, string) result Lwt.t =
  (match migration_files schema_dir with
  | Error msg -> Lwt.return (Error msg)
  | Ok migs ->
    with_db url (fun conn ->
      let prefix = List.filter (fun m -> m.version < upto) migs in
      apply_list conn prefix
      |> Lwt.map (function
           | Ok s -> Ok (s ^ " — schema snapshot applied (version < " ^ string_of_int upto ^ ")")
           | Error e -> Error e)))
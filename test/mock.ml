(** Minimal in-process HTTP/1.1 server for tests.

    Serves canned responses on 127.0.0.1 from a blocking thread; the test
    code drives the real [cohttp] client against it, so the whole stack
    (headers, gzip handling, error codes) is exercised without a network. *)

type resp = {
  code : int;
  content_type : string;
  body : string;
}

(** [start handler] binds a listener on 127.0.0.1 (random port) and serves
    [handler path body] on a dedicated thread. Returns the port and the
    listening socket (close it to stop the server). *)
let start (handler : string -> string -> resp option) : int * Unix.file_descr =
  let sock = Unix.(socket PF_INET SOCK_STREAM 0) in
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen sock 8;
  let port =
    match Unix.getsockname sock with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "unexpected socket address" in

  let send_all fd s =
    let b = Bytes.of_string s in
    let off = ref 0 in
    while !off < Bytes.length b do
      off := !off + Unix.send fd b !off (Bytes.length b - !off) []
    done
  in

  let read_all c n =
    let b = Bytes.create n in
    let off = ref 0 in
    while !off < n do
      let k = Unix.recv c b !off (n - !off) [] in
      if k = 0 then raise (Failure "connection closed mid-request");
      off := !off + k
    done;
    Bytes.to_string b
  in

  let has_header_end b len =
    let n = 4 in
    if len < n then false
    else
      let s = Bytes.to_string (Bytes.sub b 0 len) in
      let found = ref false in
      for i = 0 to len - n do
        if String.sub s i n = "\r\n\r\n" then found := true
      done;
      !found
  in

let read_request c =
    (* header part *)
    let hdr = Bytes.create 8192 in
    let off = ref 0 in
    let complete = ref false in
    while not !complete do
      let k = Unix.recv c hdr !off (8192 - !off) [] in
      if k = 0 then raise (Failure "connection closed in headers");
      off := !off + k;
      complete := has_header_end hdr !off;
      if !off = 8192 && not !complete then raise (Failure "headers too large")
    done;
    let hdr_s = Bytes.to_string (Bytes.sub hdr 0 !off) in
    (* the last recv may have delivered header bytes AND part of the body
       (TCP coalescing): split on the first CRLFCRLF and keep the excess —
       it must not be lost or [read_body] would wait for bytes already
       consumed. *)
    let (hdr_only, extra) =
      match String.index_from_opt hdr_s 0 '\r' with
      | None -> (hdr_s, "")
      | Some _ ->
        let n = 4 in
        let found = ref (-1) in
        for i = 0 to String.length hdr_s - n do
          if String.sub hdr_s i n = "\r\n\r\n" then (found := i; ())
        done;
        (match !found with
         | -1 -> (hdr_s, "")
         | i -> (String.sub hdr_s 0 i, String.sub hdr_s (i + n) (String.length hdr_s - i - n)))
    in
    let lines = String.split_on_char '\n' hdr_only in
    let request_line = String.trim (List.hd lines) in
    let parts = String.split_on_char ' ' request_line in
    let path =
      match parts with
      | _meth :: p :: _ -> p
      | _ -> "/"
    in
    let content_length =
      let cl = ref 0 in
      List.iter
        (fun l ->
          let l = String.lowercase_ascii (String.trim l) in
          if String.starts_with l ~prefix:"content-length:"
          then
            (try cl := int_of_string (String.trim (String.sub l 15 (String.length l - 15)))
             with Failure _ -> ()))
        lines;
      !cl
    in
    (path, content_length, extra)
  in

  let read_body c clen pre =
    if clen <= String.length pre then String.sub pre 0 clen
    else pre ^ read_all c (clen - String.length pre)
  in

  let respond c resp_ =
    let head =
      let reason =
        match resp_.code with
        | 200 -> "OK" | 201 -> "Created" | 400 -> "Bad Request" | 404 -> "Not Found"
        | 429 -> "Too Many Requests" | 500 -> "Internal Server Error"
        | _ -> "Unknown"
      in
      Printf.sprintf
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
        resp_.code reason resp_.content_type (String.length resp_.body)
    in
    send_all c head;
    send_all c resp_.body
  in

  Thread.create (fun () ->
      (* select with a timeout instead of a bare [Unix.accept]: the test
         closes the listening socket from the main thread, and a thread
         parked in [accept] would otherwise never wake up, keeping the
         process alive forever (OCaml threads are non-daemon). Closing the
         fd makes the next [select] raise [Unix_error], ending the loop. *)
      try
        while true do
          let (readable, _, _) = Unix.select [ sock ] [] [] 0.2 in
          if List.mem sock readable then
            (let c, _ = Unix.accept sock in
             (try
                let (path, clen, pre) = read_request c in
                let body = read_body c clen pre in
                (match handler path body with
                 | Some resp_ -> respond c resp_
                 | None -> respond c { code = 404; content_type = "text/plain"; body = "not found" })
               with _ -> ()) ;
             Unix.close c)
        done
      with Unix.Unix_error _ -> ()) ()
    |> fun _ -> (port, sock)

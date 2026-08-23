(** Minimal HTTP client on cohttp-lwt-unix.

    raguesslighter only ever GETs (SEC EDGAR) and POSTs JSON (OpenAI-compatible
    inference servers). This module centralises the two things both need:
    retries with exponential backoff on 429/5xx, and a client-side
    rate limiter so we stay under SEC's fair-access ceiling of
    10 requests/second (default ~9). *)

(** Error returned when a request fails after all retries. *)
type error = {
  status : int;
  url : string;
  body : string;
}

exception Http_error of error

let show_error e =
  Printf.sprintf "HTTP %d from %s: %s"
    e.status
    e.url
    (String.sub e.body 0 (min 200 (String.length e.body)))

(** Client-side rate limiter.

    [run th thunk] serialises on a mutex and sleeps as needed so that
    requests start at least [min_interval] apart. The default of 0.11 s
    corresponds to ~9 req/s, comfortably under SEC's 10 req/s policy. *)
module Throttle : sig
  type t

  val create : ?min_interval:float -> unit -> t
  val run : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t
end = struct
  type t = {
    min_interval : float;
    mutex : Lwt_mutex.t;
    mutable last : float;
  }

  let create ?(min_interval = 0.11) () =
    { min_interval; mutex = Lwt_mutex.create (); last = 0.0 }

  let run (t : t) (thunk : unit -> 'a Lwt.t) : 'a Lwt.t =
    Lwt_mutex.with_lock t.mutex (fun () ->
      let now = Unix.time () in
      let wait = t.last +. t.min_interval -. now in
      let start =
        if wait > 0.0
        then Lwt_unix.sleep wait
        else Lwt.return_unit
      in
      Lwt.bind start (fun () ->
        t.last <- Unix.time ();
        thunk ()))
end

(** Headers for JSON requests (OpenAI-compatible servers). *)
let json_headers ?(user_agent = "raguesslighter/0.1") ?(auth = None) () :
    Http.Header.t =
  Cohttp.Header.of_list
    ( [ "User-Agent", user_agent
      ; "Content-Type", "application/json"
      ; "Accept", "application/json"
      ; "Accept-Encoding", "gzip" ]
    @ (match auth with
       | Some a when a <> "" -> [ "Authorization", "Bearer " ^ a ]
       | _ -> []) )

(** Headers for SEC EDGAR requests (the User-Agent is the fair-access
    contact identity, per https://www.sec.gov/os/fair-access). We ask for
    gzip: the sitemaps shrink ~30x and [request] transparently decodes. *)
let sec_headers ~user_agent () =
  Cohttp.Header.of_list
    [ "User-Agent", user_agent
    ; "Accept", "application/xml, application/json, text/html;q=0.9, */*;q=0.8"
    ; "Accept-Encoding", "gzip" ]

(* Test hook: scales the retry backoff delay. Production leaves it at 1.0;
   the e2e tests set it to 0.0 so 429/5xx fault-injection runs (which retry
   to exhaustion) finish instantly. *)
let backoff_scale = ref 1.0
let set_backoff_scale (f : float) = backoff_scale := f

let backoff attempt = min (0.5 *. 2.0 ** float_of_int attempt *. !backoff_scale) 30.0

let request ?throttle ?retries ~headers ?(body = None) meth url :
    string Lwt.t =
  let retries = Option.value ~default:5 retries in
  let rec go attempt =
    (* The request must be a *thunk*: building the [Client.call] promise
       would start the request immediately, before [Throttle.run] sleeps,
       so the rate limiter would only work by accident (sequential code
       paths). *)
    let call () =
      Cohttp_lwt_unix.Client.call
        ~headers
        ?body:
          (match body with
           | Some b -> Some (Cohttp_lwt.Body.of_string b)
           | None -> None)
        meth
        (Uri.of_string url)
    in
    let task =
      match throttle with
      | Some th -> Throttle.run th call
      | None -> call ()
    in
    Lwt.bind task (fun (res, body) ->
      let code = Cohttp.Code.code_of_status (Cohttp.Response.status res) in
      Lwt.bind (Cohttp_lwt.Body.to_string body) (fun s ->
        (* cohttp never decodes gzip; do it ourselves when the body is
           actually gzip (checked by magic bytes, not by headers). *)
        let s =
          if Gz.is_gzip s
          then
            (try Gz.gunzip s
             with Gz.Error m ->
               raise (Http_error { status = code; url; body = m }))
          else s
        in
        if 200 <= code && code < 300 then Lwt.return s
        else if (code = 429 || code >= 500) && attempt < retries then
          Lwt.bind (Lwt_unix.sleep (backoff attempt)) (fun () ->
            go (attempt + 1))
        else raise (Http_error { status = code; url; body = s })))
  in
  go 0

let get ?throttle ?retries ~headers url : string Lwt.t =
  request ?throttle ?retries ~headers (`GET) url

let post_json ?throttle ?retries ~headers url ~body : string Lwt.t =
  request ?throttle ?retries ~headers ~body:(Some body) (`POST) url
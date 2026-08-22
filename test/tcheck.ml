(* Shared helpers for the alcotest 1.9.1 test suite: exception predicates for
   [T.match_raises] and testables for values without a built-in one. *)
module T = Alcotest.V1

let failure_pred (e : exn) = match e with Failure _ -> true | _ -> false

let missing_pred (e : exn) = match e with Config.Missing _ -> true | _ -> false

let expecting_pred (e : exn) = match e with Json.Expecting _ -> true | _ -> false

let gz_error_pred (e : exn) = match e with Gz.Error _ -> true | _ -> false

let api_error_pred (e : exn) = match e with Openai.Api_error _ -> true | _ -> false

let http_error_pred (e : exn) = match e with Net.Http_error _ -> true | _ -> false

(** [contains s sub] — [String.contains] only tests single characters; this
    one tests substrings. *)
let contains (s : string) (sub : string) : bool =
  let n = String.length sub in
  let l = String.length s in
  if l < n then false
  else
    let found = ref false in
    for i = 0 to l - n do
      if String.sub s i n = sub then found := true
    done;
    !found

(* Yojson has no built-in testable: compare on the canonical form, show the
   pretty JSON. *)
let yojson : Yojson.Safe.t T.testable =
  T.testable
    (fun ppf j -> Yojson.Safe.pretty_print ppf j)
    (fun a b -> a = b)

let yojson_option : Yojson.Safe.t option T.testable = T.option yojson

let yojson_assoc : (string * Yojson.Safe.t) list T.testable =
  T.list (T.pair T.string yojson)

let yojson_list : Yojson.Safe.t list T.testable = T.list yojson
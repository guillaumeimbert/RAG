(** Small extraction helpers for [Yojson.Safe] values.

    Yojson 3.x dropped the old [as_*] coercions, so ragueshlighter carries a
    handful of strict, well-named replacements. Every helper raises
    {!Expecting} with the offending JSON on type mismatch, which keeps
    "the SEC API changed its response" failures loud and debuggable. *)

module J = Yojson.Safe

(** Raised when a JSON value has a different shape than expected. *)
exception Expecting of { got : string; want : string }

(** [show j] is [j] serialized as canonical JSON.
    (Not [Yojson.Safe.show]: yojson 3 repurposed that function to print the
    OCaml representation, which is useless in error messages and not
    round-trippable through [from_string].) *)
let show = J.to_string

let string j =
  match j with
  | `String s -> s
  | other -> raise (Expecting { got = show other; want = "a string" })

let int j =
  match j with
  | `Int i -> i
  | `Intlit s ->
    (try int_of_string s
     with Failure _ -> raise (Expecting { got = show j; want = "an int" }))
  | `Float f ->
    if Float.(f = floor f) then int_of_float f
    else raise (Expecting { got = show j; want = "an int" })
  | other -> raise (Expecting { got = show other; want = "an int" })

let float j =
  match j with
  | `Float f -> f
  | `Int i -> float_of_int i
  | other -> raise (Expecting { got = show other; want = "a float" })

let bool j =
  match j with
  | `Bool b -> b
  | other -> raise (Expecting { got = show other; want = "a bool" })

let list j =
  match j with
  | `List l -> l
  | other -> raise (Expecting { got = show other; want = "a list" })

let assoc j =
  match j with
  | `Assoc a -> a
  | other -> raise (Expecting { got = show other; want = "an object" })

let member k j =
  match j with
  | `Assoc a ->
    (match List.assoc_opt k a with
     | Some v -> v
     | None -> raise (Expecting { got = show j; want = "member " ^ k }))
  | other -> raise (Expecting { got = show other; want = "an object" })

(** [option j] is [None] for JSON null and [Some j] otherwise. *)
let option j =
  match j with
  | `Null -> None
  | x -> Some x

let string_option j = option j |> Option.map string
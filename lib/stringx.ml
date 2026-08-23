(** String utilities.

    This opam repository only carries astring 0.8.5, whose [String] module
    predates [pad_left] / [drop_suffix] / [replace] / [starts_with]. Rather
    than pin an older API we [include] the standard library [String] module
    (OCaml >= 4.13 semantics: immutable strings, [String.trim], [String.sub],
    [String.length], ...) and add the handful of helpers it lacks. Modules
    that want the full surface can do [module String = Stringx]. *)

include String

(** [starts_with s ~prefix] is true when [s] begins with [prefix]. *)
let starts_with s ~prefix =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(** [ends_with s ~suffix] is true when [s] ends with [suffix]. *)
let ends_with s ~suffix =
  String.length s >= String.length suffix
  && String.sub s (String.length s - String.length suffix) (String.length suffix)
     = suffix

(** [drop_prefix s ~prefix] removes [prefix] when present (else [s]). *)
let drop_prefix s ~prefix =
  if starts_with s ~prefix
  then String.sub s (String.length prefix) (String.length s - String.length prefix)
  else s

(** [drop_suffix s ~suffix] removes [suffix] when present (else [s]). *)
let drop_suffix s ~suffix =
  if ends_with s ~suffix
  then String.sub s 0 (String.length s - String.length suffix)
  else s

(** [pad_left s ~length ~with_:c] left-pads [s] with [c] to [length]
    (no-op when already long enough). *)
let pad_left s ~length ~with_:c =
  if String.length s >= length then s else String.make (length - String.length s) c ^ s

(** [lsplit2 s ~on:c] splits [s] on the first occurrence of [c].
    Returns [(before, after)] or [None] when [c] is absent. *)
let lsplit2 s ~on =
  try
    let i = String.index s on in
    Some (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))
  with Not_found -> None

(** [replace s ~sub ~by] replaces every (non-overlapping) occurrence of
    [sub] in [s] by [by].
    @raise Failure when [sub] is empty. *)
let replace s ~sub ~by =
  if sub = "" then failwith "Stringx.replace: empty sub";
  let n = String.length sub in
  let buf = Buffer.create (String.length s) in
  let pos = ref 0 in
  let l = String.length s in
  while !pos + n <= l do
    if String.sub s !pos n = sub
    then (
      Buffer.add_string buf by;
      pos := !pos + n)
    else (
      Buffer.add_char buf (String.get s !pos);
      incr pos)
  done;
  if !pos < l then Buffer.add_string buf (String.sub s !pos (l - !pos));
  Buffer.contents buf

(** [utf8_boundary_before s n] = the greatest index [i <= min (n, length s)]
    at which a UTF-8 character begins, i.e. the safe cut point to truncate
    [s] to a prefix without splitting a multi-byte character. A cut point
    [i] is valid iff the byte at [i] is a *lead* byte (not a UTF-8
    continuation byte [10xxxxxx]); the function backs off from [n] to the
    nearest such point. (End-of-string and byte 0 are valid boundaries.) *)
let utf8_boundary_before (s : string) (n : int) : int =
  let i = ref (min n (String.length s)) in
  while !i > 0 && (Char.code (String.get s !i) land 0xC0) = 0x80 do
    decr i
  done;
  !i

(** [utf8_prefix s n] = [s] cut to a prefix of at most [n] bytes on a
    UTF-8 character boundary (no multi-byte character is split). *)
let utf8_prefix (s : string) (n : int) : string =
  if String.length s <= n
  then s
  else String.sub s 0 (utf8_boundary_before s n)

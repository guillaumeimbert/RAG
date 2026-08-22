(** HTML -> text extraction for SEC EDGAR filing documents.

    SEC filings are iXBRL HTML: mostly prose, wrapped in tables and inline
    XBRL tags. The pipeline is a small number of regex passes:

    1. drop noise blocks (script / style / head / title / ix:header);
    2. turn headings (h1-h6) into section markers;
    3. turn block-level tags into newlines;
    4. strip all remaining tags;
    5. decode character entities;
    6. squeeze whitespace.

    The result is a list of [Chunk.block]: contiguous text under the most
    recent heading. That feeds [Chunk.chunks] and the [section] column.

    Regexes use re 1.14's pure-OCaml Pcre subset: no backreferences,
    non-greedy [*?] supported, [DOTALL] flag where [.] must cross lines. *)

module String = Stringx

let tag_re = Re.compile (Re.Pcre.re "<[^>]*>")

(* ------------------------------------------------------------------ *)
(* Stage 1: noise blocks                                                *)
(* ------------------------------------------------------------------ *)

(** [noise_pair tag] matches an opening [<tag...>] (the character after the
    tag name must start attributes or close the tag, so e.g. [head] does not
    match [header]) and everything up to the matching close tag. *)
let noise_pair tag =
  Re.compile
    (Re.Pcre.re ~flags:[`DOTALL]
       (Printf.sprintf "<%s([ \t\n/][^>]*|>).*?</%s>" tag tag) )

let noise_res = List.map noise_pair [ "script"; "style"; "head"; "title"; "ix:header" ]

let strip_noise s =
  List.fold_left (fun s re -> Re.replace_string re ~by:" " s) s noise_res

(* ------------------------------------------------------------------ *)
(* Stage 2: headings -> section markers                                 *)
(* ------------------------------------------------------------------ *)

let sanitize s =
  let s = Re.replace_string tag_re ~by:"" s in
  Re.replace_string (Re.compile (Re.Pcre.re "[\n\r]+")) ~by:" " s

let mark_heading level s =
  let re =
    Re.compile
      (Re.Pcre.re ~flags:[`DOTALL]
         (Printf.sprintf "<h%d([ \t\n/][^>]*|>)(.*?)</h%d>" level level) )
  in
  Re.replace re ~f:(fun g ->
      (* group 1 is the post-tag-name part (attributes or ">"), group 2 the
         heading text. *)
      let inner = sanitize (Re.Group.get g 2) in
      if inner = ""
      then ""
      else "\x1fH" ^ string_of_int level ^ "\x1f" ^ inner ^ "\x1e")
    s

let mark_headings s = List.fold_left (fun s level -> mark_heading level s) s [ 6; 5; 4; 3; 2; 1 ]

(* ------------------------------------------------------------------ *)
(* Stage 3: block tags -> newlines                                      *)
(* ------------------------------------------------------------------ *)

let block_tag_re =
  Re.compile
    (Re.Pcre.re
       "</?(p|div|li|tr|td|th|table|thead|tbody|ul|ol|dl|dt|dd|br|hr|section|article|aside|header|footer|main|nav|blockquote|pre|figure|figcaption|center)([ \t\n/][^>]*|>)" )

(* ------------------------------------------------------------------ *)
(* Stage 5: entities                                                    *)
(* ------------------------------------------------------------------ *)

let entity_re =
  Re.compile (Re.Pcre.re "&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);")

let named_entities : (string * string) list =
  [ ("amp", "&")
  ; ("lt", "<")
  ; ("gt", ">")
  ; ("quot", "\"")
  ; ("apos", "'")
  ; ("nbsp", " ")
  ; ("ndash", "\226\128\147")  (* U+2013 *)
  ; ("mdash", "\226\128\148")  (* U+2014 *)
  ; ("hellip", "\226\128\146")  (* U+2026 *)
  ; ("lsquo", "\226\128\150")  (* U+2018 *)
  ; ("rsquo", "\226\128\151")  (* U+2019 *)
  ; ("ldquo", "\226\128\154")  (* U+201C *)
  ; ("rdquo", "\226\128\155")  (* U+201D *)
  ; ("copy", "\194\145")  (* U+00A9 *)
  ; ("reg", "\194\174")  (* U+00AE *)
  ; ("trade", "\226\134\162")  (* U+2122 *)
  ; ("aacute", "\194\161")
  ; ("agrave", "\194\160")
  ; ("eacute", "\194\169")
  ; ("egrave", "\194\168")
  ; ("iacute", "\194\173")
  ; ("oacute", "\194\179")
  ; ("uacute", "\194\185")
  ; ("ccedil", "\194\170")
  ; ("shy", "")
  ; ("zwnj", "")
  ]

(** Encode a Unicode code point to UTF-8. (The stdlib [Uchar] module has no
    bytes-producing helper, so we do the 4-case encoding by hand.) *)
let encode_utf8 (i : int) : string =
  if i < 128
  then String.make 1 (Char.chr (i land 0x7F))
  else if i < 0x800
  then
    String.init 2 (fun k ->
        if k = 0
        then Char.chr (0xC0 lor ((i lsr 6) land 0x3F))
        else Char.chr (0x80 lor (i land 0x3F)))
  else if i < 0x10000
  then
    String.init 3 (fun k ->
        match k with
        | 0 -> Char.chr (0xE0 lor ((i lsr 12) land 0x0F))
        | 1 -> Char.chr (0x80 lor ((i lsr 6) land 0x3F))
        | _ -> Char.chr (0x80 lor (i land 0x3F)))
  else
    String.init 4 (fun k ->
        match k with
        | 0 -> Char.chr (0xF0 lor ((i lsr 18) land 0x07))
        | 1 -> Char.chr (0x80 lor ((i lsr 12) land 0x3F))
        | 2 -> Char.chr (0x80 lor ((i lsr 6) land 0x3F))
        | _ -> Char.chr (0x80 lor (i land 0x3F)))

let decode_codepoint i : string option =
  if i < 0 || i > 0x10FFFF || (0xD800 <= i && i <= 0xDFFF)
  then None
  else Some (encode_utf8 i)

let decode_entity enc =
  let cp : int option =
    if String.starts_with enc ~prefix:"#x" then
      (try Some (int_of_string ("0x" ^ String.sub enc 2 (String.length enc - 2)))
       with Failure _ -> None)
    else if String.starts_with enc ~prefix:"#" then
      (try Some (int_of_string (String.sub enc 1 (String.length enc - 1)))
       with Failure _ -> None)
    else None
  in
  match cp with
  | Some i -> decode_codepoint i
  | None ->
    (match List.assoc_opt enc named_entities with
     | Some s -> Some s
     | None -> None)

let decode_entities s =
  Re.replace entity_re ~f:(fun g ->
      let enc = Re.Group.get g 1 in
      match decode_entity enc with
      | Some s -> s
      | None -> "&" ^ enc ^ ";")
    s

(* ------------------------------------------------------------------ *)
(* Stage 6: whitespace                                                  *)
(* ------------------------------------------------------------------ *)

let hws_re = Re.compile (Re.Pcre.re "[ \t\r][ \t\r]+")
let nls_re = Re.compile (Re.Pcre.re "\n+")

let squeeze s =
  let s = Re.replace_string hws_re ~by:" " s in
  Re.replace_string nls_re ~by:"\n" s

(* ------------------------------------------------------------------ *)
(* Section walk                                                         *)
(* ------------------------------------------------------------------ *)

let marker_re =
  Re.compile (Re.Pcre.re ~flags:[`DOTALL] "\x1fH([1-6])\x1f(.*?)\x1e")

let section_of stack =
  match stack with
  | [] -> ""
  | (_, t) :: _ -> t

(** [of_html html] extracts the document text, grouped under headings.
    The first block (cover page etc.) has section [""]. *)
let of_html (html : string) : Chunk.block list =
  let s =
    squeeze
      (decode_entities
         (Re.replace_string tag_re ~by:""
            (Re.replace_string block_tag_re ~by:"\n"
               (mark_headings (strip_noise html)))))
  in
  let blocks = ref ([] : Chunk.block list) in
  let stack = ref ([] : (int * string) list) in
  let r = ref 0 in
  let emit end_ =
    let t = String.trim (String.sub s !r (end_ - !r)) in
    if t <> "" then blocks := { section = section_of !stack; text = t } :: !blocks;
    r := end_
  in
  let rec loop () =
    match Re.exec_opt marker_re s ~pos:!r with
    | None -> emit (String.length s)
    | Some g ->
      (* emit the text *before* the marker, then skip the marker itself
         (advancing past it: re-searching from [start] would find the same
         marker again and loop forever). *)
      emit (Re.Group.start g 0);
      r := Re.Group.stop g 0;
      let lvl = int_of_string (Re.Group.get g 1) in
      let title = String.trim (Re.Group.get g 2) in
      let rec pop = function
        | (l, _) :: rest when l >= lvl -> pop rest
        | st -> st
      in
      stack := (lvl, title) :: pop !stack;
      loop ()
  in
  loop ();
  List.rev !blocks
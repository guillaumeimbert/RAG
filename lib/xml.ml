(** Minimal well-formed XML reader for the SEC ownership filings
    (13D / 13G / 13F), which carry machine-readable XML alongside their
    XSL-rendered HTML.

    This is deliberately a small in-house parser (in the spirit of
    [Json] and [Html_text]) rather than a new dependency: the subset of
    XML that EDGAR filings actually use is tiny. It handles element
    nesting, attributes (discarded), self-closing tags, comments,
    processing instructions, DOCTYPE declarations, XML namespaces
    (prefixes are kept in [name]; match with {!local_name} to be
    prefix-agnostic) and the standard character references. It does not
    handle CDATA sections or DTD-defined entities. *)

(** One node of the parsed document. [Elem.name] keeps any namespace
    prefix ([ns:name]); use {!local_name} when matching by name. *)
type node =
  | Text of string
  | Elem of { name : string; children : node list }

exception Parse_error of string

(** [parse_error_at pos msg] raises [Parse_error] annotated with the byte
    offset. Module-level so it stays polymorphic (usable where an [int],
    a [node] or [unit] is expected); a local let with a polymorphic
    annotation is not reliably re-instantiated per use in OCaml. *)
let parse_error_at (pos : int) (msg : string) : 'a =
  raise (Parse_error (Printf.sprintf "xml: %s (at byte %d)" msg pos))

(** [local_name "ns:name"] = ["name"]; [local_name "name"] = ["name"]. *)
let local_name (s : string) : string =
  match String.index_from_opt s 0 ':' with
  | Some i -> String.sub s (i + 1) (String.length s - i - 1)
  | None -> s

let is_name_char (c : char) : bool =
  let o = Char.code c in
  (o >= 65 && o <= 90) || (o >= 97 && o <= 122) || (o >= 48 && o <= 57)
  || c = '_' || c = '-' || c = '.' || c = ':'

(** Append a Unicode code point as UTF-8 bytes. *)
let add_utf8 (b : Buffer.t) (v : int) =
  if v < 0x80
  then Buffer.add_char b (Char.chr v)
  else if v < 0x800
  then
    ( Buffer.add_char b (Char.chr (0xC0 lor (v lsr 6)));
      Buffer.add_char b (Char.chr (0x80 lor (v land 0x3F))) )
  else if v < 0x10000
  then
    ( Buffer.add_char b (Char.chr (0xE0 lor (v lsr 12)));
      Buffer.add_char b (Char.chr (0x80 lor ((v lsr 6) land 0x3F)));
      Buffer.add_char b (Char.chr (0x80 lor (v land 0x3F))) )
  else
    ( Buffer.add_char b (Char.chr (0xF0 lor (v lsr 18)));
      Buffer.add_char b (Char.chr (0x80 lor ((v lsr 12) land 0x3F)));
      Buffer.add_char b (Char.chr (0x80 lor ((v lsr 6) land 0x3F)));
      Buffer.add_char b (Char.chr (0x80 lor (v land 0x3F))) )

(** [parse s] parses a complete XML document into its top-level elements.
    Text outside the root element (prolog whitespace) is discarded.
    @raise Parse_error on malformed input. *)
let parse (s : string) : node list =
  let len = String.length s in
  let p = ref 0 in
  (** Find [needle] at or after [!p] (bytes are searched linearly). *)
  let find_from (needle : string) : int option =
    let nl = String.length needle in
    if nl = 0 || !p + nl > len then None
    else
      let i = ref !p in
      let found = ref None in
      while !i + nl <= len && Option.is_none !found do
        if String.compare (String.sub s !i nl) needle = 0
        then found := Some !i
        else incr i
      done;
      !found
  in
  let skip_ws () =
    let stop = ref false in
    while !p < len && not !stop do
      let c = String.get s !p in
      if c = ' ' || c = '\t' || c = '\n' || c = '\r' then incr p
      else stop := true
    done
  in
  (* Skip one processing instruction ([<?...?>]), comment or DOCTYPE.
     DOCTYPE declarations may legally contain '>' inside [ ... ], so
     balance the brackets. Precondition: [s[!p] = '<']. *)
  let skip_decl () =
    if !p + 2 > len then parse_error_at !p "truncated declaration"
    else
      match String.sub s !p 2 with
      | "<?" ->
        (match find_from "?>" with
         | Some i -> p := i + 2
         | None -> parse_error_at !p "unterminated processing instruction")
      | "<!" ->
        if !p + 3 <= len && String.sub s (!p + 2) 2 = "--"
        then
          (match find_from "-->" with
           | Some i -> p := i + 3
           | None -> parse_error_at !p "unterminated comment")
        else
          let depth = ref 0 in
          let stop = ref false in
          while !p < len && not !stop do
            let c = String.get s !p in
            if c = '[' then incr depth
            else if c = ']' then decr depth
            else if c = '>' && !depth <= 0 then (incr p; stop := true)
            else incr p
          done
      | _ -> parse_error_at !p "unexpected declaration"
  in
  (* Parse prolog declarations up to the first element. *)
  let rec skip_prolog () =
    skip_ws ();
    if !p < len && String.get s !p = '<'
    then
      match String.sub s !p (min 2 (len - !p)) with
      | "<?" | "<!" -> (skip_decl (); skip_prolog ())
      | _ -> ()
  in
  (* Append the character reference at [!p] (= '&') to [tbuf]. *)
  let parse_entity (tbuf : Buffer.t) =
    let semi =
      (match String.index_from_opt s !p ';' with
       | Some i -> i
       | None -> parse_error_at !p "unterminated character reference")
    in
    let ent = String.sub s (!p + 1) (semi - !p - 1) in
    p := semi + 1;
    match ent with
    | "amp" -> Buffer.add_char tbuf '&'
    | "lt" -> Buffer.add_char tbuf '<'
    | "gt" -> Buffer.add_char tbuf '>'
    | "quot" -> Buffer.add_char tbuf '"'
    | "apos" -> Buffer.add_char tbuf '\''
    | "nbsp" -> Buffer.add_char tbuf ' '
    | _ ->
      let (digits, hex) =
        if String.starts_with ent ~prefix:"#x" || String.starts_with ent ~prefix:"#X"
        then (String.sub ent 2 (String.length ent - 2), true)
        else if String.starts_with ent ~prefix:"#"
        then (String.sub ent 1 (String.length ent - 1), false)
        else (ent, false)
      in
      let v =
        (try
           if hex then int_of_string ("0x" ^ digits) else int_of_string digits
         with Failure _ -> parse_error_at !p "bad numeric character reference")
      in
      if v = 0 || (0xD800 <= v && v <= 0xDFFF) || v > 0x10FFFF
      then parse_error_at !p "bad numeric character reference"
      else add_utf8 tbuf v
  in
  (* Parse one element starting at [!p] (= '<', not a declaration) and
     return it. Text runs inside the element are accumulated and flushed
     as Text nodes before each child element and at the end. *)
  let rec parse_element () =
    if !p >= len || String.get s !p <> '<'
    then parse_error_at !p "expected an element"
    else
      ( incr p;
        let start = !p in
        while !p < len && is_name_char (String.get s !p) do
          incr p
        done;
        if !p = start then parse_error_at !p "empty element name"
        else
          let name = local_name (String.sub s start (!p - start)) in
          skip_ws ();
          let self_closing = ref false in
          (* Attributes: skip name/value pairs. Quoted values may contain
             '>' or '<', so scan to the matching quote. *)
          let stop = ref false in
          while !p < len && not !stop && String.get s !p <> '>'
          do
            let c = String.get s !p in
            match c with
            | '"' | '\'' ->
              ( incr p;
                (try p := String.index_from s !p c
                 with Not_found -> parse_error_at !p "unterminated attribute value");
                incr p )
            | '/' ->
              ( incr p;
                skip_ws ();
                if !p < len && String.get s !p = '>'
                then (self_closing := true; incr p; stop := true)
                else parse_error_at !p "unexpected '/' in start tag" )
            | _ -> incr p
          done;
          if !self_closing
          then Elem { name; children = [] }
          else
            let tbuf =
              (* the attribute scan stops before the closing '>'; consume it *)
              (if !p >= len || String.get s !p <> '>'
               then parse_error_at !p "unterminated start tag"
               else (incr p; Buffer.create 256))
            in
            let children = ref [] in
            let flush_text () =
              let t = Buffer.contents tbuf in
              if t <> ""
              then (children := Text t :: !children; Buffer.clear tbuf)
            in
            (* Parse the element content until the matching end tag. *)
            let rec parse_content () =
              if !p >= len
              then parse_error_at !p ("unexpected EOF inside element <" ^ name ^ ">")
              else if String.get s !p <> '<'
              then
                ( match String.get s !p with
                  | '&' -> (parse_entity tbuf; parse_content ())
                  | c -> (Buffer.add_char tbuf c; incr p; parse_content ()) )
              else
                match String.sub s !p (min 2 (len - !p)) with
                | "</" ->
                  ( flush_text ();
                    incr p;
                    incr p;
                    let start = !p in
                    while !p < len && is_name_char (String.get s !p) do
                      incr p
                    done;
                    let close_name = local_name (String.sub s start (!p - start)) in
                    skip_ws ();
                    if !p >= len || String.get s !p <> '>'
                    then parse_error_at !p "malformed end tag"
                    else
                      ( incr p;
                        if close_name <> name
                        then
                          parse_error_at !p
                            ( "mismatched end tag: expected </" ^ name
                            ^ ", got </" ^ close_name ^ ">" ) ) )
                | "<?" | "<!" -> (skip_decl (); parse_content ())
                | _ ->
                  ( flush_text ();
                    let child = parse_element () in
                    children := child :: !children;
                    parse_content () )
            in
            parse_content ();
            flush_text ();
            Elem { name; children = List.rev !children } )
  in
  skip_prolog ();
  let children = ref [] in
  let rec loop () =
    skip_ws ();
    if !p < len
    then
      match String.sub s !p (min 2 (len - !p)) with
      | "<?" | "<!" -> (skip_decl (); loop ())
      | _ ->
        (children := parse_element () :: !children; loop ())
  in
  loop ();
  List.rev !children

(* ------------------------------------------------------------------ *)
(* Tree queries                                                        *)
(* ------------------------------------------------------------------ *)

let is_elem (name : string) (n : node) : bool =
  match n with
  | Elem e -> local_name e.name = name
  | Text _ -> false

(** First child element of [n] whose local names is [name]. *)
let elem (name : string) (n : node) : node option =
  match n with
  | Elem e -> List.find_opt (is_elem name) e.children
  | Text _ -> None

(** All child elements of [n] whose local name is [name], document order. *)
let elems (name : string) (n : node) : node list =
  match n with
  | Elem e -> List.filter (is_elem name) e.children
  | Text _ -> []

(** Follow a chain of child-element names from [n]. *)
let path (names : string list) (n : node) : node option =
  let rec go (names : string list) (acc : node) : node option =
    match names with
    | [] -> Some acc
    | h :: tl -> (match elem h acc with Some c -> go tl c | None -> None)
  in
  go names n

(** Descendant text of [n]: all nested text, whitespace collapsed. *)
let rec text_of (n : node) : string =
  match n with
  | Text t -> t
  | Elem e ->
    let b = Buffer.create 64 in
    List.iter
      (fun c ->
        let t = text_of c in
        if t <> ""
        then
          (if Buffer.length b > 0 then Buffer.add_char b ' ';
           Buffer.add_string b t))
      e.children;
    Re.replace_string (Re.compile (Re.Pcre.re "[ \\t\\n\\r]+")) ~by:" "
      (Buffer.contents b)
    |> String.trim

(** Text of the first child element [name] of [n] (whitespace collapsed). *)
let child_text (name : string) (n : node) : string option =
  Option.map (fun e -> text_of e) (elem name n)

let path_text (names : string list) (n : node) : string option =
  Option.map (fun e -> text_of e) (path names n)
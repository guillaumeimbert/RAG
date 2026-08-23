(** Building the grounded-ask prompt: numbered excerpts and the Sources list.

    The citation number assigned to a hit is used BOTH in the prompt the LLM
    sees and in the "Sources" list printed after its answer, so the model's
    "[n]" markers map back to a specific filing. Keeping the numbering in one
    place (and testing it) prevents a silent off-by-one that would make the
    LLM cite the wrong filing. *)

let meta (h : Store.hit) : string =
  let ticker = if h.ticker = "" then "" else " (" ^ h.ticker ^ ")" in
  let section = if h.section = "" then "" else ", \"" ^ h.section ^ "\"" in
  h.company ^ ticker ^ " — " ^ h.form ^ ", filed " ^ h.filed_at ^ section

(** [truncate s n] = [s] cut to at most [n] bytes (roughly characters for
    ASCII text), suffixed with an ellipsis when shortened. The cut is backed
    off to a UTF-8 character boundary so a multi-byte character is never split
    (a dangling lead byte would make the LLM request body invalid UTF-8 and
    the server reject it). *)
let truncate (s : string) (n : int) : string =
  if String.length s <= n
  then s
  else String.sub s 0 (Stringx.utf8_boundary_before s n) ^ " …"

let excerpt_of (i : int) (h : Store.hit) : string =
  Format.sprintf "[%d] %s\n%s" (i + 1) (meta h) (truncate h.text 900)

(** The numbered excerpts block given to the LLM: one "[n]" marker per hit, so
    the [i]-th hit is always labelled "[i+1]". *)
let excerpts (hits : Store.hit list) : string =
  String.concat "\n\n" (List.mapi excerpt_of hits)

let source_line (i : int) (h : Store.hit) : string =
  Printf.sprintf "  [%d] %s\n" (i + 1) (meta h)

(** The "Sources" block printed after the answer; shares [excerpts] numbering
    so "[n]" in the model's output resolves to the [n]-th source line. *)
let sources (hits : Store.hit list) : string =
  String.concat "" (List.mapi source_line hits)
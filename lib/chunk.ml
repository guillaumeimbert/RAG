(** Chunking of parsed filing text into embedding-sized blocks.

    A filing is a list of [{section; text}] blocks (see [Html_text]); each
    block belongs to one section. [chunks] merges blocks of the *same*
    section until the target size is reached, then cuts. Rules:
    - a chunk never exceeds [size] characters (a word may be force-cut);
    - a chunk belongs to exactly one section (a section boundary always
      flushes the pending chunk);
    - consecutive chunks from the same section share at most [overlap]
      characters (the tail of the previous chunk, starting at a word
      boundary). *)

type block = {
  section : string;
  text : string;
}

(** Cut [s] to at most [maxlen] characters, preferring a word boundary;
    force-cuts when there is none. *)
let head_cut s maxlen =
  if String.length s <= maxlen then s
  else
    let cut =
      let p = ref (min maxlen (String.length s - 1)) in
      while !p > 0 && String.get s !p <> ' ' && String.get s !p <> '\n' do
        decr p
      done;
      if !p = 0 then maxlen else !p
    in
    String.sub s 0 cut

(** Last [n] characters of [s] starting at a word boundary ("" when the
    tail is a single word or shorter than [n]). Trimmed. *)
let tail_overlap s n =
  if n <= 0 || String.length s <= n then ""
  else
    let p = ref (String.length s - n) in
    while !p < String.length s && String.get s !p <> ' ' && String.get s !p <> '\n' do
      incr p
    done;
    if !p >= String.length s then ""
    else Stringx.trim (String.sub s !p (String.length s - !p))

(** Cut [s] (longer than [size]) into successive chunks of at most [size]
    characters, chaining the [overlap] tail of each chunk into the next.
    Assumes [s] is a single section's text. *)
let cut_chunks s ~size ~overlap =
  let rec go s acc =
    if String.length s <= size
    then (let s = Stringx.trim s in if s = "" then List.rev acc else List.rev ((s :: acc)))
    else
      let head =
        let head = Stringx.trim (head_cut s size) in
        if head = "" then String.sub s 0 size else head
      in
      let rem =
        Stringx.trim (String.sub s (String.length head) (String.length s - String.length head))
      in
      let ov = tail_overlap head overlap in
      let next =
        if rem = "" then ov
        else if ov = "" then rem
        else ov ^ " " ^ rem
      in
      go next (head :: acc)
  in
  go s []

let chunks (blocks : block list) ~size ~overlap : block list =
  if size <= 0 then failwith "chunks: size must be > 0";
  if blocks = [] then []
  else
    let rec go section acc blocks =
      match blocks with
      | [] ->
        (let acc = Stringx.trim acc in
         if acc = "" then []
         else if String.length acc < size then [{ section; text = acc }]
         else cut_chunks acc ~size ~overlap |> List.map (fun text -> { section; text }))
      | b :: rest ->
        if b.section <> section && acc <> ""
        then
          (* section boundary: flush the pending chunk; [b] starts fresh. *)
          { section; text = acc } :: go b.section b.text rest
        else
          let text = if acc = "" then b.text else acc ^ " " ^ b.text in
          if String.length text >= size
          then
            let head =
              let head = Stringx.trim (head_cut text size) in
              if head = "" then String.sub text 0 (min size (String.length text))
              else head
            in
            let rem =
              Stringx.trim
                (String.sub text (String.length head)
                   (String.length text - String.length head))
            in
            let ov = tail_overlap head overlap in
            let next =
              if rem = "" then ov
              else if ov = "" then rem
              else ov ^ " " ^ rem
            in
            { section; text = head } :: go section next rest
          else go b.section text rest
    in
    let b0 = List.hd blocks in
    go b0.section b0.text (List.tl blocks)
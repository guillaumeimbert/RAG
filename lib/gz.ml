(** Minimal gzip (RFC 1952) decompressor on top of [zlib].

    SEC EDGAR serves some static resources (notably the daily-index
    sitemaps) gzip-compressed, either server-side or in response to
    [Accept-Encoding: gzip]. OCaml's cohttp never negotiates or decodes
    gzip itself, so [Net] transparently decompresses any response body
    that starts with the gzip magic bytes via this module.

    Implementation notes:
    - uses zlib's incremental [flate] API with [window_bits = 47]
      (32 + 15: auto-detect the gzip or zlib format, 32 KiB window);
    - multi-member streams are supported (zlib consumes each member's
      CRC32/ISIZE trailer before signalling end of stream, and
      [Zlib.reset] keeps the format detection for the next member);
    - the deflate stream integrity is checked by zlib; the gzip trailer
      CRC32 is consumed but not re-verified here (transport is TLS and a
      corrupt body will fail loudly at parse time anyway). *)

exception Error of string

let magic = "\031\139"  (* 0x1f 0x8b = decimal 31 139 *)

let is_gzip s = String.length s >= 2 && String.sub s 0 2 = magic

(** The [zlib] binding works on bigarrays of one-byte elements; the stdlib
    has no string <-> bigstring conversion, so we do it by hand. *)
type bigstring = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

let bigstring_of_string (s : string) : bigstring =
  let b = Bigarray.(Array1.create char c_layout (String.length s)) in
  for i = 0 to String.length s - 1 do
    Bigarray.Array1.set b i (String.get s i)
  done;
  b

let string_of_bigstring (b : bigstring) (ofs : int) (len : int) : string =
  String.init len (fun i -> Bigarray.Array1.get b (ofs + i))

(** [gunzip s] decompresses a gzip stream [s].
    @raise Error when [s] is not a complete, valid gzip stream. *)
let gunzip (s : string) : string =
  if not (is_gzip s) then raise (Error "bad gzip magic bytes");
  let t = (Zlib.create_inflate ~window_bits:47 ()) in
  t.Zlib.in_buf <- bigstring_of_string s;
  t.in_ofs <- 0;
  t.in_len <- -1;  (* the whole buffer *)
  let chunk = 65536 in
  t.out_buf <- bigstring_of_string (String.make chunk '\000');
  t.out_ofs <- 0;
  t.out_len <- -1;  (* the whole chunk *)
  let out = Buffer.create 16384 in
  let rec go () =
    let in0 = t.Zlib.in_total in
    let out0 = t.Zlib.out_ofs in
    let st = Zlib.flate t Zlib.No_flush in
    let produced = t.Zlib.out_ofs - out0 in
    if produced > 0 then
      ( (* drain what was produced into [out] *)
        Buffer.add_string out (string_of_bigstring t.out_buf out0 produced);
        t.out_ofs <- 0;
        t.out_len <- -1 );
    match st with
    | Zlib.Stream_end ->
      if t.in_len > 0 then ( Zlib.reset t;  (* next member of a multi-member stream *)
                             go () )
    | Zlib.Ok ->
      if t.in_total = in0 && produced = 0
      then raise (Error "no progress (truncated or corrupt stream)")
      else go ()
    | Zlib.Buf_error -> raise (Error "no progress (truncated or corrupt stream)")
    | Zlib.Data_error m ->
      raise (Error ("zlib: " ^ (if m = "" then "data error" else m)))
    | Zlib.Need_dict -> raise (Error "preset dictionary not supported")
  in
  go ();
  Buffer.contents out
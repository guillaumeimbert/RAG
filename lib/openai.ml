(** Client for OpenAI-compatible inference endpoints.

    Two operations are used:
    - chat completions ([/chat/completions]) for grounded answering
    - embeddings ([/embeddings]) for ingestion and query embedding

    The server, models and credentials all come from [Config.t] (i.e. .env);
    nothing is assumed beyond the two HTTP routes. Works with vLLM, llama.cpp,
    ninfer, Azure-style gateways and the real OpenAI API.

    The response parsing lives in pure functions ([parse_chat_response],
    [parse_embeddings_response]) so it can be unit-tested without a server. *)

type role = [ `System | `User | `Assistant ]

type message = {
  role : role;
  content : string;
}

(** Raised when the server answers with something unusable. *)
exception Api_error of string

let role_string = function
  | `System -> "system"
  | `User -> "user"
  | `Assistant -> "assistant"

let headers cfg =
  Net.json_headers ~auth:(Some cfg.Config.openai_api_key) ()

let headers_embed cfg =
  Net.json_headers ~auth:(Some cfg.Config.openai_embed_api_key) ()

let parse_json context s =
  match Yojson.Safe.from_string s with
  | j -> j
  | exception Yojson.Json_error _ ->
    raise
      ( Api_error
        ( "invalid JSON from inference server (" ^ context ^ "): "
        ^ String.sub s 0 (min 300 (String.length s)) ) )

let of_messages messages =
  List.map
    (fun m ->
      `Assoc
        [ "role", `String (role_string m.role); "content", `String m.content ])
    messages

(** Parse a [/chat/completions] response body into the completion text.
    @raise Api_error when the response is not valid JSON, has no choices,
    or the chosen message content is empty. *)
let parse_chat_response (s : string) : string =
  (try
     let j = parse_json "chat/completions" s in
     match Json.list (Json.member "choices" j) with
     | [] -> raise (Api_error ("no choices in chat response: " ^ s))
     | c0 :: _ ->
       let content =
         Json.string (Json.member "content" (Json.member "message" c0))
       in
       if content = ""
       then raise (Api_error ("empty chat completion: " ^ s))
       else content
   with Json.Expecting e ->
     raise
       (Api_error
          (Printf.sprintf "malformed chat response (want %s, got %s): %s" e.want e.got s)))

(** Parse a [/embeddings] response body into one vector per input row,
    re-sorted by the server's [index] field (servers occasionally reorder
    results). [dim] > 0 enforces the expected vector length.
    @raise Api_error on invalid JSON or a dimension mismatch. *)
let parse_embeddings_response ?(dim = 0) (s : string) : (float list) list =
  (try
     let j = parse_json "embeddings" s in
     let rows =
       Json.list (Json.member "data" j)
       |> List.map (fun d ->
              ( Json.int (Json.member "index" d),
                Json.list (Json.member "embedding" d) |> List.map Json.float ))
       |> List.sort (fun (i, _) (j, _) -> Int.compare i j)
     in
     List.iter
       (fun (_, vec) ->
         if dim > 0 && List.length vec <> dim
         then
           raise
             ( Api_error
               (Printf.sprintf
                  "embedding dimension mismatch: server returned %d-dim vectors \
                   but expected %d (is the model loaded?)"
                  (List.length vec) dim) ))
       rows;
     List.map snd rows
   with Json.Expecting e ->
     raise
       (Api_error
          (Printf.sprintf "malformed embeddings response (want %s, got %s)" e.want e.got)))

(** One chat completion. [?system] prepends a system message; [?temperature]
    defaults to 0.2 (near-deterministic but not robotic). *)
let chat ?system ?(temperature = 0.2) ~cfg (messages : message list) : string Lwt.t =
  let msgs =
    (match system with
     | Some s -> [ `Assoc [ "role", `String "system"; "content", `String s ] ]
     | None -> [])
    @ of_messages messages
  in
  let payload =
    `Assoc
      [ "model", `String cfg.Config.llm_model
      ; "messages", `List msgs
      ; "temperature", `Float temperature ]
  in
  Lwt.bind
    (Net.post_json
       ~headers:(headers cfg)
       (cfg.Config.openai_base_url ^ "/chat/completions")
       ~body:(Yojson.Safe.to_string payload))
    (fun s -> Lwt.return (parse_chat_response s))

(** Embed a batch of texts. Returns one vector per input, in input order.
    @raise Api_error if the server's row count does not match the input
    count (a dropped row would silently misalign texts and vectors). *)
let embed ~cfg (texts : string list) : (float list) list Lwt.t =
  if texts = []
  then Lwt.return []
  else
    let payload =
      `Assoc
        [ "model", `String cfg.Config.embedding_model
        ; "input", `List (List.map (fun t -> `String t) texts) ]
    in
    Lwt.bind
      (Net.post_json
         ~headers:(headers_embed cfg)
         (cfg.Config.openai_embed_base_url ^ "/embeddings")
         ~body:(Yojson.Safe.to_string payload))
      (fun s ->
        let vecs =
          parse_embeddings_response ~dim:cfg.Config.embedding_dim s
        in
        if List.length vecs <> List.length texts
        then
          raise
            ( Api_error
              (Printf.sprintf
                 "embedding count mismatch: server returned %d vectors for %d \
                  inputs"
                 (List.length vecs) (List.length texts)) )
        else Lwt.return vecs)
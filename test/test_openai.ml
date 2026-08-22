module T = Alcotest.V1
module F = Test_fixtures


let tests : (string * unit T.test_case list) list =
  [
    (
      "parse_chat_response",
      [
        T.test_case "fixture pins the format" `Quick (fun () ->
            T.check T.string "mismatch" "Per the filings [1], revenue grew 129%." (Openai.parse_chat_response (F.read_text (F.fix "chat_response.json"))));
        T.test_case "invalid JSON raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.api_error_pred (fun () -> ignore (Openai.parse_chat_response "not json")));
        T.test_case "no choices raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.api_error_pred (fun () -> ignore (Openai.parse_chat_response "{\"choices\": []}")));
        T.test_case "empty content raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.api_error_pred (fun () -> ignore (Openai.parse_chat_response
                  "{\"choices\": [{\"message\": {\"role\": \"assistant\", \"content\": \"\"}}]}")));
      ] );
    (
      "parse_embeddings_response",
      [
        T.test_case "fixture re-sorts by index" `Quick (fun () ->
            (* the fixture lists index 1 before index 0 *)
            T.check (T.list (T.list (T.float 0.))) "mismatch" [ [ 0.1; 0.2; 0.3 ]; [ 0.4; 0.5; 0.6 ] ] (Openai.parse_embeddings_response (F.read_text (F.fix "embeddings_response.json"))));
        T.test_case "dim check passes" `Quick (fun () ->
            T.check T.int "mismatch" 3 (List.length
                 (List.hd
                    (Openai.parse_embeddings_response ~dim:3
                       (F.read_text (F.fix "embeddings_response.json"))))));
        T.test_case "dim mismatch raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.api_error_pred (fun () -> ignore (Openai.parse_embeddings_response ~dim:8
                  (F.read_text (F.fix "embeddings_response.json")))));
        T.test_case "invalid JSON raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.api_error_pred (fun () -> ignore (Openai.parse_embeddings_response "[]")));
        T.test_case "missing data member raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.api_error_pred (fun () -> ignore (Openai.parse_embeddings_response "{\"object\":\"list\"}")));
      ] );
  ]
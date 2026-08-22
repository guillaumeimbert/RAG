module T = Alcotest.V1

(** Checker for [Json.Expecting {got; want}]. *)

let obj = Yojson.Safe.from_string "{\"a\": \"x\", \"b\": 1, \"c\": 2.5, \"d\": true, \"e\": null, \"f\": [1, 2], \"g\": {\"h\": \"i\"}}"

let tests : (string * unit T.test_case list) list =
  [
    (
      "string / int / float / bool",
      [
        T.test_case "string ok" `Quick (fun () ->
            T.check T.string "mismatch" "x" (Json.string (`String "x")));
        T.test_case "string mismatch" `Quick (fun () ->
            T.match_raises "raises" Tcheck.expecting_pred (fun () -> ignore (Json.string (`Int 1))));
        T.test_case "int from Int" `Quick (fun () -> T.check T.int "mismatch" 42 (Json.int (`Int 42)));
        T.test_case "int from Intlit" `Quick (fun () -> T.check T.int "mismatch" 7 (Json.int (`Intlit "7")));
        T.test_case "int from whole Float" `Quick (fun () -> T.check T.int "mismatch" 3 (Json.int (`Float 3.0)));
        T.test_case "int from fractional Float" `Quick (fun () ->
            T.match_raises "raises" Tcheck.expecting_pred (fun () -> ignore (Json.int (`Float 3.5))));
        T.test_case "float from Int" `Quick (fun () -> T.check (T.float 0.)  "mismatch" 3.0 (Json.float (`Int 3)));
        T.test_case "bool ok" `Quick (fun () -> T.check T.bool "mismatch" true (Json.bool (`Bool true)));
        T.test_case "bool mismatch" `Quick (fun () ->
            T.match_raises "raises" Tcheck.expecting_pred (fun () -> ignore (Json.bool (`String "true"))));
      ] );
    (
      "container helpers",
      [
        T.test_case "list ok" `Quick (fun () ->
            T.check Tcheck.yojson_list "mismatch" [ `Int 1; `Int 2 ] (Json.list (`List [`Int 1; `Int 2])));
        T.test_case "list mismatch" `Quick (fun () ->
            T.match_raises "raises" Tcheck.expecting_pred (fun () -> ignore (Json.list (`Int 1))));
        T.test_case "assoc ok" `Quick (fun () ->
            T.check Tcheck.yojson_assoc "mismatch" [ ("a", `Int 1) ] (Json.assoc (`Assoc [ "a", `Int 1 ])));
        T.test_case "option of null" `Quick (fun () ->
            T.check Tcheck.yojson_option "mismatch" None (Json.option `Null));
        T.test_case "option of value" `Quick (fun () ->
            T.check (T.option T.string) "mismatch" (Some "v") (Json.string_option (`String "v")));
        T.test_case "string_option of null" `Quick (fun () ->
            T.check (T.option T.string) "mismatch" None (Json.string_option `Null));
      ] );
    (
      "member",
      [
        T.test_case "present" `Quick (fun () ->
            T.check Tcheck.yojson "mismatch" (`String "x") (Json.member "a" obj));
        T.test_case "nested" `Quick (fun () ->
            T.check T.string "mismatch" "i" (Json.string (Json.member "h" (Json.member "g" obj))));
        T.test_case "missing member raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.expecting_pred (fun () -> ignore (Json.member "zzz" obj)));
        T.test_case "member on non-object raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.expecting_pred (fun () -> ignore (Json.member "a" (`List []))));
      ] );
    (
      "show",
      [
        T.test_case "round-trips an object" `Quick (fun () ->
            let s = Json.show obj in
            T.check Tcheck.yojson "mismatch" obj (Yojson.Safe.from_string s));
      ] );
  ]
module T = Alcotest.V1

(** Compare a split result to the expected list of statements. *)
let check_split (sql : string) (expected : string list) : unit =
  T.check
    (Alcotest.list T.string)
    "unexpected statements"
    expected
    (Migration.split_statements sql)

let tests : (string * unit T.test_case list) list =
  [
    (
      "split_statements: simple statements",
      [
        T.test_case "single statement" `Quick (fun () ->
            check_split "CREATE TABLE a (x int);" ["CREATE TABLE a (x int)"]);
        T.test_case "multiple statements" `Quick (fun () ->
            check_split
              "CREATE TABLE a (x int); CREATE TABLE b (y int);"
              ["CREATE TABLE a (x int)"; "CREATE TABLE b (y int)"]);
        T.test_case "empty input" `Quick (fun () -> check_split "" []);
        T.test_case "trailing semicolon and whitespace" `Quick (fun () ->
            check_split "CREATE TABLE a (x int);   " ["CREATE TABLE a (x int)"]);
      ] );
    (
      "split_statements: dollar-quoted DO block",
      [
        T.test_case "DO block is one statement" `Quick (fun () ->
            check_split
              "DO $$ BEGIN RAISE NOTICE 'hi;'; END $$; CREATE TABLE a (x int);"
              ["DO $$ BEGIN RAISE NOTICE 'hi;'; END $$"; "CREATE TABLE a (x int)"]);
        T.test_case "tagged dollar quote" `Quick (fun () ->
            check_split
              "DO $tag$ BEGIN PERFORM f('a;'); END $tag$;"
              ["DO $tag$ BEGIN PERFORM f('a;'); END $tag$"]);
      ] );
    (
      "split_statements: quoted strings",
      [
        T.test_case "semicolon in a string literal" `Quick (fun () ->
            check_split
              "INSERT INTO a VALUES ('x;y'); INSERT INTO a VALUES ('z');"
              ["INSERT INTO a VALUES ('x;y')"; "INSERT INTO a VALUES ('z')"]);
        T.test_case "escaped single quote" `Quick (fun () ->
            check_split
              "INSERT INTO a VALUES ('it''s; fine'); CREATE TABLE b (y int);"
              ["INSERT INTO a VALUES ('it''s; fine')"; "CREATE TABLE b (y int)"]);
      ] );
    (
      "split_statements: comments",
      [
        T.test_case "line comment with a semicolon" `Quick (fun () ->
            check_split
              "-- a comment; not a split\nCREATE TABLE a (x int);"
              ["-- a comment; not a split\nCREATE TABLE a (x int)"]);
        T.test_case "block comment with a semicolon" `Quick (fun () ->
            check_split
              "/* a; comment */\nCREATE TABLE a (x int);"
              ["/* a; comment */\nCREATE TABLE a (x int)"]);
        T.test_case "comment then statement" `Quick (fun () ->
            check_split
              "-- first\nCREATE TABLE a (x int); -- second\nCREATE TABLE b (y int);"
              ["-- first\nCREATE TABLE a (x int)"; "-- second\nCREATE TABLE b (y int)"]);
      ] );
    (
      "split_statements: realistic migration",
      [
        T.test_case "ALTER TABLE with a trigger function" `Quick (fun () ->
            check_split
              "CREATE TABLE IF NOT EXISTS t (id int);\nCREATE OR REPLACE FUNCTION f() RETURNS trigger AS $$\nBEGIN\n  INSERT INTO log VALUES (NEW.id, 'a;b');\n  RETURN NEW;\nEND\n$$ LANGUAGE plpgsql;\nCREATE TRIGGER trg AFTER INSERT ON t FOR EACH ROW EXECUTE FUNCTION f();"
              [ "CREATE TABLE IF NOT EXISTS t (id int)"
              ; "CREATE OR REPLACE FUNCTION f() RETURNS trigger AS $$\nBEGIN\n  INSERT INTO log VALUES (NEW.id, 'a;b');\n  RETURN NEW;\nEND\n$$ LANGUAGE plpgsql"
              ; "CREATE TRIGGER trg AFTER INSERT ON t FOR EACH ROW EXECUTE FUNCTION f()" ]);
      ] );
    (
      "validate_history_versions: applied prefix check",
      [
        T.test_case "valid full prefix" `Quick (fun () ->
            T.check T.bool "should be Ok" true
              (match Migration.validate_history_versions [ 1; 2; 3 ] [ 1; 2; 3 ]
               with Ok () -> true | Error _ -> false));
        T.test_case "valid partial prefix" `Quick (fun () ->
            T.check T.bool "should be Ok" true
              (match Migration.validate_history_versions [ 1; 2; 3 ] [ 1; 2 ]
               with Ok () -> true | Error _ -> false));
        T.test_case "empty history" `Quick (fun () ->
            T.check T.bool "should be Ok" true
              (match Migration.validate_history_versions [ 1; 2; 3 ] [ ]
               with Ok () -> true | Error _ -> false));
        T.test_case "gap is an error" `Quick (fun () ->
            T.check T.bool "should be Error" true
              (match Migration.validate_history_versions [ 1; 2; 3 ] [ 1; 3 ]
               with Error _ -> true | Ok () -> false));
        T.test_case "unknown version is an error" `Quick (fun () ->
            T.check T.bool "should be Error" true
              (match Migration.validate_history_versions [ 1; 2 ] [ 1; 5 ]
               with Error _ -> true | Ok () -> false));
        T.test_case "missing file is an error" `Quick (fun () ->
            T.check T.bool "should be Error" true
              (match Migration.validate_history_versions [ 1; 3 ] [ 1; 2 ]
               with Error _ -> true | Ok () -> false));
        T.test_case "more applied than local is an error" `Quick (fun () ->
            T.check T.bool "should be Error" true
              (match Migration.validate_history_versions [ 1; 2 ] [ 1; 2; 3 ]
               with Error _ -> true | Ok () -> false));
        T.test_case "applied out of order is normalized" `Quick (fun () ->
            T.check T.bool "should be Ok" true
              (match Migration.validate_history_versions [ 1; 2 ] [ 2; 1 ]
               with Ok () -> true | Error _ -> false));
      ] );
  ]
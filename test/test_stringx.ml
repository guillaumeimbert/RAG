module T = Alcotest.V1

let tests : (string * unit T.test_case list) list =
  [
    (
      "starts_with / drop_prefix",
      [
        T.test_case "prefix present" `Quick (fun () ->
            T.check T.bool "mismatch" true (Stringx.starts_with "hello world" ~prefix:"hello"));
        T.test_case "prefix absent" `Quick (fun () ->
            T.check T.bool "mismatch" false (Stringx.starts_with "hello world" ~prefix:"world"));
        T.test_case "prefix longer than string" `Quick (fun () ->
            T.check T.bool "mismatch" false (Stringx.starts_with "hi" ~prefix:"higher"));
        T.test_case "empty prefix" `Quick (fun () ->
            T.check T.bool "mismatch" true (Stringx.starts_with "hi" ~prefix:""));
        T.test_case "drop_prefix removes" `Quick (fun () ->
            T.check T.string "mismatch" "s://x" (Stringx.drop_prefix "https://x" ~prefix:"http"));
        T.test_case "drop_prefix no-op when absent" `Quick (fun () ->
            T.check T.string "mismatch" "https://x" (Stringx.drop_prefix "https://x" ~prefix:"ftp"));
      ] );
    (
      "ends_with / drop_suffix",
      [
        T.test_case "suffix present" `Quick (fun () ->
            T.check T.bool "mismatch" true (Stringx.ends_with "file.html" ~suffix:".html"));
        T.test_case "suffix absent" `Quick (fun () ->
            T.check T.bool "mismatch" false (Stringx.ends_with "file.html" ~suffix:".txt"));
        T.test_case "drop_suffix removes" `Quick (fun () ->
            T.check T.string "mismatch" "https://x" (Stringx.drop_suffix "https://x/" ~suffix:"/"));
        T.test_case "drop_suffix no-op when absent" `Quick (fun () ->
            T.check T.string "mismatch" "https://x" (Stringx.drop_suffix "https://x" ~suffix:"/"));
      ] );
    (
      "pad_left",
      [
        T.test_case "pads short" `Quick (fun () ->
            T.check T.string "mismatch" "0001045810" (Stringx.pad_left ~length:10 ~with_:'0' "1045810"));
        T.test_case "no-op when long enough" `Quick (fun () ->
            T.check T.string "mismatch" "0001045810" (Stringx.pad_left ~length:10 ~with_:'0' "0001045810"));
        T.test_case "no-op when longer" `Quick (fun () ->
            T.check T.string "mismatch" "12345" (Stringx.pad_left ~length:3 ~with_:'0' "12345"));
      ] );
    (
      "lsplit2",
      [
        T.test_case "splits at first occurrence" `Quick (fun () ->
            T.check (T.option (T.pair T.string T.string)) "mismatch" (Some ("a", "b=c")) (Stringx.lsplit2 "a=b=c" ~on:'='));
        T.test_case "absent separator" `Quick (fun () ->
            T.check (T.option (T.pair T.string T.string)) "mismatch" None (Stringx.lsplit2 "abc" ~on:'='));
        T.test_case "empty before" `Quick (fun () ->
            T.check (T.option (T.pair T.string T.string)) "mismatch" (Some ("", "x")) (Stringx.lsplit2 "=x" ~on:'='));
      ] );
    (
      "replace",
      [
        T.test_case "all occurrences" `Quick (fun () ->
            T.check T.string "mismatch" "c-b-c" (Stringx.replace "a-b-a" ~sub:"a" ~by:"c"));
        T.test_case "no occurrence" `Quick (fun () ->
            T.check T.string "mismatch" "abc" (Stringx.replace "abc" ~sub:"z" ~by:"q"));
        T.test_case "multi-char" `Quick (fun () ->
            T.check T.string "mismatch" "x-x" (Stringx.replace "x--x" ~sub:"--" ~by:"-"));
        T.test_case "empty sub raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Stringx.replace "a" ~sub:"" ~by:"b")));
      ] );
    (
      "utf8_boundary_before / utf8_prefix",
      [
        T.test_case "backs off a split 2-byte character" `Quick (fun () ->
            (* "abcde" + e-acute (C3 A9): byte 6 is the continuation byte
               A9; the safe cut backs off to 5. *)
            T.check T.int "mismatch" 5 (Stringx.utf8_boundary_before "abcde\xc3\xa9" 6));
        T.test_case "backs off a split 3-byte character" `Quick (fun () ->
            (* "abcd" + em dash (E2 80 94): byte 5 is a continuation byte;
               the safe cut backs off to 4. *)
            T.check T.int "mismatch" 4 (Stringx.utf8_boundary_before "abcd\xe2\x80\x94" 5));
        T.test_case "no backoff at an ASCII boundary" `Quick (fun () ->
            T.check T.int "mismatch" 3 (Stringx.utf8_boundary_before "abcdef" 3));
        T.test_case "long multi-byte word: cut lands on a boundary" `Quick (fun () ->
            let acc = String.concat "" (List.init 599 (fun _ -> "\xc3\xa9")) in
            (* 1198 bytes; 101 is a continuation byte -> back off to 100. *)
            T.check T.int "mismatch" 100 (Stringx.utf8_boundary_before acc 101));
        T.test_case "prefix keeps whole characters" `Quick (fun () ->
            let acc = String.concat "" (List.init 599 (fun _ -> "\xc3\xa9")) in
            let expected = String.concat "" (List.init 50 (fun _ -> "\xc3\xa9")) in
            T.check T.string "mismatch" expected (Stringx.utf8_prefix acc 101));
        T.test_case "prefix shorter than n is unchanged" `Quick (fun () ->
            T.check T.string "mismatch" "ab\xc3\xa9" (Stringx.utf8_prefix "ab\xc3\xa9" 10));
        T.test_case "end-of-string is a valid boundary (n = length)" `Quick (fun () ->
            (* n = the full length (4 for "ab\xc3\xa9"): the cut point is the
               end of the string; it must not read s.[length] (out of bounds). *)
            T.check T.int "mismatch" 4 (Stringx.utf8_boundary_before "ab\xc3\xa9" 4));
        T.test_case "n past the end clamps to the end boundary" `Quick (fun () ->
            T.check T.int "mismatch" 4 (Stringx.utf8_boundary_before "ab\xc3\xa9" 99));
        T.test_case "prefix with n >= length returns the whole string" `Quick (fun () ->
            T.check T.string "mismatch" "ab\xc3\xa9" (Stringx.utf8_prefix "ab\xc3\xa9" 4));
      ] );
  ]
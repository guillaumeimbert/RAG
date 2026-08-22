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
  ]
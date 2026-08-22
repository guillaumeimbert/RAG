module T = Alcotest.V1
module F = Test_fixtures

(** 31 139 = the gzip magic bytes (0x1f 0x8b). *)
let magic = String.make 1 (Char.chr 31) ^ String.make 1 (Char.chr 139)


let tests : (string * unit T.test_case list) list =
  [
    (
      "is_gzip",
      [
        T.test_case "magic bytes" `Quick (fun () -> T.check T.bool "mismatch" true (Gz.is_gzip (magic ^ "rest")));
        T.test_case "no magic" `Quick (fun () -> T.check T.bool "mismatch" false (Gz.is_gzip "plain"));
        T.test_case "too short" `Quick (fun () -> T.check T.bool "mismatch" false (Gz.is_gzip "x"));
        T.test_case "wrong magic" `Quick (fun () -> T.check T.bool "mismatch" false (Gz.is_gzip (String.make 2 '\139')));
      ] );
    (
      "gunzip",
      [
        T.test_case "single member" `Quick (fun () ->
            let expected = String.concat "" (List.init 100 (fun _ -> "hello world\n")) in
            T.check T.string "mismatch" expected (Gz.gunzip (F.read_bin (F.fix "hello.gz"))));
        T.test_case "multi-member stream" `Quick (fun () ->
            T.check T.string "mismatch" "first member\nsecond member\n" (Gz.gunzip (F.read_bin (F.fix "hello_multi.gz"))));
        T.test_case "truncated stream raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.gz_error_pred (fun () -> ignore (Gz.gunzip (F.read_bin (F.fix "hello_trunc.gz")))));
        T.test_case "non-gzip input raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.gz_error_pred (fun () -> ignore (Gz.gunzip "definitely not gzip")));
        T.test_case "empty input raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.gz_error_pred (fun () -> ignore (Gz.gunzip "")));
        T.test_case "corrupt member body raises" `Quick (fun () ->
            (* valid 10-byte gzip header, then a garbage deflate stream *)
            let hdr =
              magic ^ String.make 1 (Char.chr 8) ^ String.make 1 (Char.chr 0)
              ^ String.make 4 (Char.chr 0) ^ String.make 1 (Char.chr 0)
              ^ String.make 1 (Char.chr 3)
            in
            T.match_raises "raises" Tcheck.gz_error_pred (fun () -> ignore (Gz.gunzip (hdr ^ String.make 16 '\255'))));
      ] );
  ]
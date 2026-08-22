module T = Alcotest.V1
module F = Test_fixtures


(** Run a Lwt thread to completion, turning [Error] into a raised exception. *)
let run (res : 'a Lwt.t) : 'a = Lwt_main.run res

let headers () = Net.sec_headers ~user_agent:"test@example.com (test)" ()

let with_mock (h : string -> string -> Mock.resp option) (f : string -> unit) : unit =
  let (port, stop) = Mock.start h in
  let base = Printf.sprintf "http://127.0.0.1:%d" port in
  let res =
    (try
       f base;
       Ok ()
     with e ->
       (stop (); raise e))
  in
  stop ();
  match res with
  | Ok () -> ()
  | Error e -> raise e

let tests : (string * unit T.test_case list) list =
  [
    (
      "get",
      [
        T.test_case "200 passes the body through" `Quick (fun () ->
            with_mock
              (fun path _body ->
                if String.starts_with path ~prefix:"/plain"
                then Some { Mock.code = 200; content_type = "text/plain"; body = "plain body" }
                else Some { Mock.code = 500; content_type = "text/plain"; body = "boom" })
              (fun base ->
                T.check T.string "mismatch" "plain body" (run (Net.get ~headers:(headers ()) (base ^ "/plain")))));
        T.test_case "gzip body is decompressed transparently" `Quick (fun () ->
            let gz = F.read_bin (F.fix "hello.gz") in
            let expected = String.concat "" (List.init 100 (fun _ -> "hello world\n")) in
            with_mock
              (fun _path _body ->
                Some { Mock.code = 200; content_type = "application/gzip"; body = gz })
              (fun base ->
                T.check T.string "mismatch" expected (run (Net.get ~headers:(headers ()) (base ^ "/x")))));
        T.test_case "404 raises Http_error" `Quick (fun () ->
            with_mock
              (fun _path _body ->
                Some { Mock.code = 404; content_type = "text/plain"; body = "not found" })
              (fun base ->
                T.match_raises "raises" Tcheck.http_error_pred (fun () -> ignore (run (Net.get ~headers:(headers ()) (base ^ "/nope"))))));
        T.test_case "malformed gzip body raises Http_error" `Quick (fun () ->
            (* gzip magic then garbage: the decompressor must fail, not pass
               the raw bytes through *)
            let bad =
              String.make 1 (Char.chr 31) ^ String.make 1 (Char.chr 139)
              ^ String.make 32 (Char.chr 255)
            in
            with_mock
              (fun _path _body ->
                Some { Mock.code = 200; content_type = "application/gzip"; body = bad })
              (fun base ->
                T.match_raises "raises" Tcheck.http_error_pred (fun () -> ignore (run (Net.get ~headers:(headers ()) (base ^ "/bad"))))));
        T.test_case "post_json round-trips the request body" `Quick (fun () ->
            with_mock
              (fun path body ->
                match (path, body) with
                | "/echo", b ->
                  Some { Mock.code = 200; content_type = "application/json"; body = b }
                | _ -> None)
              (fun base ->
                let b = "{\"model\": \"m\", \"input\": [\"hi\"]}" in
                T.check T.string "mismatch" b (run
                     (Net.post_json ~headers:(Net.json_headers ~auth:(Some "k") ())
                        (base ^ "/echo")
                        ~body:b))));
      ] );
  ]
(** Unit tests for the pure helpers in [Store] (no database required). *)
module T = Alcotest.V1

let inv_pred (e : exn) : bool = match e with Invalid_argument _ -> true | _ -> false

let tests : (string * unit T.test_case list) list =
  [
    (
      "candidate_of",
      [
        T.test_case "top_k=1 -> 5 (5x, and >= top_k)" `Quick (fun () ->
            T.check T.int "candidate count" 5 (Store.candidate_of 1));
        T.test_case "top_k=5 -> 25" `Quick (fun () ->
            T.check T.int "candidate count" 25 (Store.candidate_of 5));
        T.test_case "top_k=10 -> 50 (the 50 cap, >= top_k)" `Quick (fun () ->
            T.check T.int "candidate count" 50 (Store.candidate_of 10));
        T.test_case "top_k=50 -> 50 (= top_k)" `Quick (fun () ->
            T.check T.int "candidate count" 50 (Store.candidate_of 50));
        T.test_case "top_k=51 -> 51 (>= top_k, NOT capped below top_k)" `Quick (fun () ->
            T.check T.int "candidate count" 51 (Store.candidate_of 51));
        T.test_case "top_k=100 -> 100 (>= top_k)" `Quick (fun () ->
            T.check T.int "candidate count" 100 (Store.candidate_of 100));
        (* The core guarantee: the candidate set is never smaller than the
           requested top_k, so --top-k N can always return N hits. *)
        T.test_case "always >= top_k across the boundary" `Quick (fun () ->
            let ks = [1; 2; 5; 9; 10; 11; 49; 50; 51; 52; 100; 250; 1000] in
            T.check T.bool "candidate_of k >= k" true
              (List.for_all (fun k -> Store.candidate_of k >= k) ks));
        T.test_case "the 5x buffer applies only below top_k=10" `Quick (fun () ->
            (* 5x up to the 50 cap, then flat at 50, then tracking top_k. *)
            T.check T.bool "shape" true
              (Store.candidate_of 3 = 15
               && Store.candidate_of 11 = 50
               && Store.candidate_of 40 = 50
               && Store.candidate_of 100 = 100));
        T.test_case "top_k=0 raises Invalid_argument" `Quick (fun () ->
            T.match_raises "rejects 0" inv_pred (fun () -> ignore (Store.candidate_of 0)));
        T.test_case "top_k<0 raises Invalid_argument" `Quick (fun () ->
            T.match_raises "rejects -3" inv_pred (fun () -> ignore (Store.candidate_of (-3))));
      ] );
  ]
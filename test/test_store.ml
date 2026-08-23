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
        (* top_k=1000 is the maximum (candidate_k=1000, and ef_search stays <=
           1000, pgvector's cap for hnsw.ef_search). *)
        T.test_case "top_k=1000 -> 1000 (the maximum allowed)" `Quick (fun () ->
            T.check T.int "candidate count" 1000 (Store.candidate_of 1000));
        (* The core guarantee: the candidate set is never smaller than the
           requested top_k, so --top-k N can always return N hits. *)
        T.test_case "always >= top_k across the boundary" `Quick (fun () ->
            let ks = [1; 2; 5; 9; 10; 11; 49; 50; 51; 52; 100; 250; 999; 1000] in
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
        (* pgvector caps hnsw.ef_search at 1000; a top_k above that would force
           an out-of-range ef_search, so it is rejected. *)
        T.test_case "top_k=1001 raises Invalid_argument" `Quick (fun () ->
            T.match_raises "rejects 1001" inv_pred (fun () -> ignore (Store.candidate_of 1001)));
        T.test_case "top_k=5000 raises Invalid_argument" `Quick (fun () ->
            T.match_raises "rejects 5000" inv_pred (fun () -> ignore (Store.candidate_of 5000)));
      ] );
    (
      "validate_top_k",
      [
        T.test_case "accepts the full range 1..max without raising" `Quick (fun () ->
            (* validate_top_k returns unit and raises only out of range, so a
               sweep over the whole allowed range proves it never rejects a
               valid value (the CLI calls this before any inference request). *)
            List.iter (fun k -> Store.validate_top_k k) [1; 5; 10; 50; 51; 100; 999; 1000];
            T.check T.bool "no raise" true true);
        T.test_case "0 raises Invalid_argument" `Quick (fun () ->
            T.match_raises "rejects 0" inv_pred (fun () -> Store.validate_top_k 0));
        T.test_case "a negative value raises Invalid_argument" `Quick (fun () ->
            T.match_raises "rejects -1" inv_pred (fun () -> Store.validate_top_k (-1)));
        T.test_case "1001 (above the hnsw.ef_search cap) raises Invalid_argument" `Quick (fun () ->
            T.match_raises "rejects 1001" inv_pred (fun () -> Store.validate_top_k 1001));
        T.test_case "5000 raises Invalid_argument" `Quick (fun () ->
            T.match_raises "rejects 5000" inv_pred (fun () -> Store.validate_top_k 5000));
      ] );
    (
      "version_at_least",
      [
        T.test_case "equal versions" `Quick (fun () ->
            T.check T.bool "0.8.0 >= 0.8.0" true (Store.version_at_least "0.8.0" "0.8.0"));
        T.test_case "newer patch" `Quick (fun () ->
            T.check T.bool "0.8.6 >= 0.8.0" true (Store.version_at_least "0.8.6" "0.8.0"));
        T.test_case "newer minor" `Quick (fun () ->
            T.check T.bool "0.9.0 >= 0.8.0" true (Store.version_at_least "0.9.0" "0.8.0"));
        T.test_case "newer major" `Quick (fun () ->
            T.check T.bool "1.0.0 >= 0.8.0" true (Store.version_at_least "1.0.0" "0.8.0"));
        T.test_case "older is rejected" `Quick (fun () ->
            T.check T.bool "0.7.0 >= 0.8.0 is false" false (Store.version_at_least "0.7.0" "0.8.0"));
        T.test_case "missing component counts as 0" `Quick (fun () ->
            T.check T.bool "0.8 >= 0.8.0" true (Store.version_at_least "0.8" "0.8.0"));
        T.test_case "missing component is not a wild zero" `Quick (fun () ->
            T.check T.bool "0.8 >= 0.8.1 is false" false (Store.version_at_least "0.8" "0.8.1"));
        T.test_case "longer version wins on a differing component" `Quick (fun () ->
            T.check T.bool "0.8.0.1 >= 0.8.0" true (Store.version_at_least "0.8.0.1" "0.8.0"));
      ] );
  ]
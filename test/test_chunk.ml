module T = Alcotest.V1

let tests : (string * unit T.test_case list) list =
  [
    (
      "head_cut",
      [
        T.test_case "short string untouched" `Quick (fun () ->
            T.check T.string "mismatch" "short" (Chunk.head_cut "short" 10));
        T.test_case "exactly maxlen untouched" `Quick (fun () ->
            T.check T.string "mismatch" "abcdefghij" (Chunk.head_cut "abcdefghij" 10));
        T.test_case "cuts at word boundary" `Quick (fun () ->
            T.check T.string "mismatch" "the quick brown fox" (Chunk.head_cut "the quick brown fox jumps" 19));
        T.test_case "force-cuts a long word" `Quick (fun () ->
            T.check T.string "mismatch" (String.make 10 'x') (Chunk.head_cut ("x" ^ String.make 20 'x') 10));
        T.test_case "word that does not fit is left behind" `Quick (fun () ->
            (* "abc " + a 12-letter word: maxlen 15 fits neither the whole
               word nor a cut inside it, so the cut falls back to the last
               complete word before maxlen. *)
            T.check T.string "mismatch" "abc" (Chunk.head_cut ("abc " ^ String.make 12 'x') 15));
        T.test_case "no boundary before maxlen -> falls back to maxlen" `Quick (fun () ->
            T.check T.string "mismatch" ("ab" ^ String.make 13 'x') (Chunk.head_cut ("ab" ^ String.make 14 'x') 15));
      ] );
    (
      "tail_overlap",
      [
        T.test_case "starts at word boundary" `Quick (fun () ->
            T.check T.string "mismatch" "fox jumps" (Chunk.tail_overlap "the quick brown fox jumps" 10));
        T.test_case "single-word tail -> empty" `Quick (fun () ->
            T.check T.string "mismatch" "" (Chunk.tail_overlap "abcdef" 3));
        T.test_case "shorter than n -> empty" `Quick (fun () ->
            T.check T.string "mismatch" "" (Chunk.tail_overlap "abc" 5));
        T.test_case "zero overlap -> empty" `Quick (fun () ->
            T.check T.string "mismatch" "" (Chunk.tail_overlap "a b c d e f g h" 0));
      ] );
    (
      "chunks",
      [
        T.test_case "empty in -> empty out" `Quick (fun () ->
            T.check (T.list (T.pair T.string T.string)) "mismatch" [] (Chunk.chunks ~size:100 ~overlap:10 []
                 |> List.map (fun b -> (b.Chunk.section, b.Chunk.text))));
        T.test_case "short single block stays one chunk" `Quick (fun () ->
            T.check (T.list (T.pair T.string T.string)) "mismatch" [ ("S", "hello") ] (Chunk.chunks ~size:100 ~overlap:10
                 [{ Chunk.section = "S"; text = "hello" }]
              |> List.map (fun b -> (b.Chunk.section, b.Chunk.text))));
        T.test_case "same-section blocks merge" `Quick (fun () ->
            T.check (T.list (T.pair T.string T.string)) "mismatch" [ ("S", "one two") ] (Chunk.chunks ~size:100 ~overlap:10
                 [ { Chunk.section = "S"; text = "one" }
                 ; { Chunk.section = "S"; text = "two" } ]
              |> List.map (fun b -> (b.Chunk.section, b.Chunk.text))));
        T.test_case "section boundary flushes" `Quick (fun () ->
            T.check (T.list (T.pair T.string T.string)) "mismatch" [ ("A", "x"); ("B", "y") ] (Chunk.chunks ~size:100 ~overlap:10
                 [ { Chunk.section = "A"; text = "x" }
                 ; { Chunk.section = "B"; text = "y" } ]
              |> List.map (fun b -> (b.Chunk.section, b.Chunk.text))));
        T.test_case "never exceeds size" `Quick (fun () ->
            let text = String.concat " " (List.init 300 (fun i -> "word" ^ string_of_int i)) in
            let cs = Chunk.chunks ~size:500 ~overlap:50 [{ Chunk.section = "S"; text }] in
            T.check T.bool "is true" true (List.for_all (fun c -> String.length c.Chunk.text <= 500) cs);
            T.check T.bool "is true" true (List.length cs >= 2));
        T.test_case "long single word is force-cut and covered" `Quick (fun () ->
            let text = String.make 1200 'w' in
            let cs = Chunk.chunks ~size:100 ~overlap:20 [{ Chunk.section = "S"; text }] in
            T.check T.bool "is true" true (List.for_all (fun c -> String.length c.Chunk.text <= 100) cs);
            T.check T.bool "is true" true (List.for_all (fun c -> String.length c.Chunk.text > 0) cs));
        T.test_case "content is preserved in order" `Quick (fun () ->
            let text =
              String.concat " " (List.init 400 (fun i -> "alpha" ^ string_of_int i)) in
            let cs =
              Chunk.chunks ~size:400 ~overlap:80 [{ Chunk.section = "S"; text }]
              |> List.map (fun c -> c.Chunk.text)
            in
            T.check T.bool "is true" true (List.for_all (fun c -> String.length c <= 400) cs);
            (* first chunk is the head-cut of the input *)
            T.check T.string "mismatch" (Stringx.trim (Chunk.head_cut text 400)) (List.hd cs);
            (* the last word reaches the last chunk *)
            T.check T.bool "is true" true (Tcheck.contains (List.hd (List.rev cs)) "alpha399"));
        T.test_case "size <= 0 fails" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Chunk.chunks ~size:0 ~overlap:10 [{ Chunk.section = "S"; text = "x" }])));
      ] );
  ]
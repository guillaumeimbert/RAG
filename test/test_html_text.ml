module T = Alcotest.V1
module F = Test_fixtures

let blocks_of (html : string) : (string * string) list =
  Html_text.of_html html |> List.map (fun b -> (b.Chunk.section, b.Chunk.text))


(** U+2013 en dash, as UTF-8. *)
let en_dash = "\226\128\147"

let tests : (string * unit T.test_case list) list =
  [
    (
      "headings -> sections",
      [
        T.test_case "heading text becomes the section" `Quick (fun () ->
            T.check (T.list (T.pair T.string T.string)) "mismatch" [ ("Sec One", "alpha\nbeta"); ("Sub", "gamma") ] (blocks_of
                 "<html><body><h1>Sec One</h1><p>alpha</p><p>beta</p><h2>Sub</h2><p>gamma</p></body></html>"));
        T.test_case "text before any heading has section \"\"" `Quick (fun () ->
            T.check (T.list (T.pair T.string T.string)) "mismatch" [ ("", "preamble"); ("H", "body") ] (blocks_of "<body><p>preamble</p><h1>H</h1><p>body</p></body>"));
        T.test_case "nested headings use the most recent one" `Quick (fun () ->
            T.check (T.list (T.pair T.string T.string)) "mismatch" [ ("C", "t") ] (blocks_of "<body><h1>A</h1><h2>B</h2><h3>C</h3><p>t</p></body>"));
        T.test_case "section change flushes the pending text" `Quick (fun () ->
            T.check (T.list (T.pair T.string T.string)) "mismatch" [ ("A", "one"); ("B", "two") ] (blocks_of "<body><h1>A</h1><p>one</p><h1>B</h1><p>two</p></body>"));
      ] );
    (
      "noise removal",
      [
        T.test_case "script/style/head/title dropped" `Quick (fun () ->
            let b =
              blocks_of
                "<html><head><title>T</title><style>.a{}</style></head><body><script>var x = 1;</script><h1>H</h1><p>ok</p></body></html>" in
            let all = String.concat " " (List.map snd b) in
            T.check T.bool "mismatch" false (String.contains all 'x');
            T.check (T.list (T.pair T.string T.string)) "mismatch" [ ("H", "ok") ] b);
        T.test_case "head does not eat header" `Quick (fun () ->
            (* <header> is a block tag: a newline, not the dropped <head> *)
            T.check (T.list (T.pair T.string T.string)) "mismatch" [ ("", "Keep me\nrest") ] (blocks_of "<body><header>Keep me</header><p>rest</p></body>"));
      ] );
    (
      "entities",
      [
        T.test_case "named and numeric entities decode" `Quick (fun () ->
            T.check T.string "mismatch" ("A & B \"C\" " ^ en_dash ^ " D \226\128\148 E F") (snd (List.hd (blocks_of "<body><p>A &amp; B &quot;C&quot; &#x2013; D &mdash; E &nbsp; F</p></body>"))));
        T.test_case "unknown entities are kept" `Quick (fun () ->
            T.check T.string "mismatch" "x &zzz; y" (snd (List.hd (blocks_of "<body><p>x &zzz; y</p></body>"))));
      ] );
    (
      "whitespace",
      [
        T.test_case "runs of spaces squeeze to one" `Quick (fun () ->
            T.check T.string "mismatch" "a b c" (snd (List.hd (blocks_of "<body><p>a   b\t\tc</p></body>"))));
        T.test_case "block tags become newlines" `Quick (fun () ->
            T.check T.string "mismatch" "l1\nl2" (snd (List.hd (blocks_of "<body><p>l1</p><p>l2</p></body>"))));
      ] );
    (
      "real 8-K fixture",
      [
        T.test_case "extracts the full text" `Quick (fun () ->
            let bs = blocks_of (F.read_text (F.fix "nvda_8k.html")) in
            T.check T.bool "mismatch" true (List.length bs >= 1);
            let all = String.concat "\n" (List.map snd bs) in
            T.check T.bool "mismatch" true (String.length all > 5000);
            T.check T.bool "mismatch" true (Tcheck.contains all "NVIDIA");
            (* no markup or section markers leak through *)
            T.check T.bool "mismatch" true (List.for_all (fun (_, t) -> not (String.contains t '<')) bs);
            T.check T.bool "mismatch" true (List.for_all (fun (s, t) -> (not (String.contains s (Char.chr 31)))
                 && (not (String.contains s (Char.chr 30))) && String.length t > 0)
                 bs));
      ] );
  ]
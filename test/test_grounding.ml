(** Citation mapping for the grounded ask prompt: the [i]-th hit must carry
    citation "[i+1]" in BOTH the excerpts block given to the LLM and the
    Sources block printed after its answer, and the same number must refer to
    the same hit in both. An off-by-one here would make the model cite the
    wrong filing. *)

module T = Alcotest.V1

let mk id company form filed_at text =
  { Store.id = id
  ; Store.doc_id = text
  ; company
  ; cik = "1"
  ; ticker = ""
  ; form
  ; filed_at
  ; section = ""
  ; text
  ; similarity = 0.9 }

let hits =
  [ mk 1 "ALPHA" "10-K" "2026-01-01" "alpha body"; mk 2 "BETA" "13G" "2026-02-02" "beta body" ]

let ex = Grounding.excerpts hits
let src = Grounding.sources hits

let tests : (string * unit T.test_case list) list =
  [
    (
      "grounding.excerpts",
      [
        T.test_case "hit i carries citation [i+1], never the other hit" `Quick (fun () ->
            T.check T.bool "citation [i+1] wrong in excerpts" true
              (Tcheck.contains ex "[1] ALPHA"
              && Tcheck.contains ex "[2] BETA"
              && not (Tcheck.contains ex "[2] ALPHA")
              && not (Tcheck.contains ex "[1] BETA")));
        T.test_case "all hits present, in order" `Quick (fun () ->
            T.check T.bool "hit missing from excerpts" true
              (Tcheck.contains ex "alpha body" && Tcheck.contains ex "beta body"));
      ] );
    (
      "grounding.sources",
      [
        T.test_case "sources share the excerpts citation mapping" `Quick (fun () ->
            T.check T.bool "citation mapping wrong in sources" true
              (Tcheck.contains src "[1] ALPHA"
              && Tcheck.contains src "[2] BETA"
              && not (Tcheck.contains src "[2] ALPHA")
              && not (Tcheck.contains src "[1] BETA")));
        T.test_case "sources list every hit" `Quick (fun () ->
            T.check T.bool "hit missing from sources" true
              (Tcheck.contains src "ALPHA" && Tcheck.contains src "BETA"));
      ] );
  ]
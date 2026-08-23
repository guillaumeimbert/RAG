(** Unit tests for the ownership-filing parsers ([Ownership]), against the
    real EDGAR XML fixtures captured from live filings. *)

module T = Alcotest.V1

let fixture name = Test_fixtures.read_text (Test_fixtures.fix name)

let meta_13g =
  {
    Ownership.accession = "0001045810-26-000062";
    filed_at = Date.of_yyyymmdd "20260720";
    index_url = "https://example.com/13g-index.htm";
  }

let meta_13d =
  {
    Ownership.accession = "0001193125-26-307988";
    filed_at = Date.of_yyyymmdd "20260716";
    index_url = "https://example.com/13d-index.htm";
  }

let meta_13f =
  {
    Ownership.accession = "0001045810-26-000065";
    filed_at = Date.of_yyyymmdd "20260814";
    index_url = "https://example.com/13f-index.htm";
  }

let tests : (string * unit T.test_case list) list =
  [
    (
      "classify",
      [
        T.test_case "narrative forms" `Quick (fun () ->
            T.check T.bool "10-K" true (Ownership.classify "10-K" = Ownership.Prose);
            T.check T.bool "10-K/A" true (Ownership.classify "10-K/A" = Ownership.Prose));
        T.test_case "ownership forms (EDGAR spellings)" `Quick (fun () ->
            T.check T.bool "13G" true (Ownership.classify "SCHEDULE 13G" = Ownership.Form13g);
            T.check T.bool "13D" true (Ownership.classify "SCHEDULE 13D" = Ownership.Form13d);
            T.check T.bool "13D/A" true (Ownership.classify "SCHEDULE 13D/A" = Ownership.Form13d);
            T.check T.bool "13F-HR" true (Ownership.classify "13F-HR" = Ownership.Form13f));
      ] );
    (
      "norm_form",
      [
        T.test_case "strips the SCHEDULE prefix" `Quick (fun () ->
            T.check T.string "mismatch" "13G" (Ownership.norm_form "SCHEDULE 13G"));
        T.test_case "keeps plain codes" `Quick (fun () ->
            T.check T.string "mismatch" "10-K" (Ownership.norm_form "10-K"));
      ] );
    (
      "of_sec_date",
      [
        T.test_case "ISO date" `Quick (fun () ->
            T.check (T.option T.string) "mismatch"
              (Some (Date.to_string (Date.of_yyyymmdd "20260713")))
              (Ownership.of_sec_date "2026-07-13" |> Option.map Date.to_string));
        T.test_case "US date" `Quick (fun () ->
            T.check (T.option T.string) "mismatch"
              (Some "2026-07-13")
              (Ownership.of_sec_date "07/13/2026" |> Option.map Date.to_string));
        T.test_case "US dashed date" `Quick (fun () ->
            T.check (T.option T.string) "mismatch"
              (Some "2026-06-30")
              (Ownership.of_sec_date "06-30-2026" |> Option.map Date.to_string));
        T.test_case "garbage -> None" `Quick (fun () ->
            T.check T.bool "garbage" true
              (Option.is_none (Ownership.of_sec_date "13/45/2026")));
      ] );
    (
      "parse_13g",
      [
        T.test_case "NVIDIA -> Nebius fixture" `Quick (fun () ->
            let (events, prose) =
              Ownership.parse_13g (fixture "13g_nvda.xml") ~meta:meta_13g
                ~form:"SCHEDULE 13G"
            in
            ( match events with
              | [ e ] ->
                T.check T.string "accession" meta_13g.Ownership.accession e.accession;
                T.check T.string "form" "13G" e.form;
                T.check T.string "event_date" "2026-07-13"
                  (Date.to_string e.event_date);
                T.check T.string "filer_cik" "0001045810" e.filer_cik;
                T.check T.string "filer_name" "NVIDIA Corporation" e.filer_name;
                T.check T.string "subject_cik" "0001513845" e.subject_cik;
                T.check T.string "subject_name" "Nebius Group N.V." e.subject_name;
                T.check T.string "class" "Class A Ordinary Shares" e.class_name;
                T.check (T.option T.int) "shares" (Some 22256412) e.shares;
                T.check (T.option (T.float 0.)) "percent" (Some 9.3) e.percent;
                T.check T.bool "passive" true e.passive;
                T.check T.bool "not an amendment" false e.is_amendment
              | _ -> T.fail "expected exactly one event");
            T.check T.bool "prose is non-empty" true (String.length prose > 0));
      ] );
    (
      "parse_13d",
      [
        T.test_case "GameStop -> eBay fixture (13D/A)" `Quick (fun () ->
            let (events, prose) =
              Ownership.parse_13d (fixture "13d_gamestop.xml") ~meta:meta_13d
                ~form:"SCHEDULE 13D/A"
            in
            ( match events with
              | [ e ] ->
                T.check T.string "form" "13D/A" e.form;
                T.check T.string "event_date" "2026-07-15"
                  (Date.to_string e.event_date);
                T.check T.string "filer_cik" "0001326380" e.filer_cik;
                T.check T.string "filer_name" "GameStop Corp." e.filer_name;
                T.check T.string "subject_cik" "0001065088" e.subject_cik;
                T.check T.string "subject_name" "eBay Inc." e.subject_name;
                T.check (T.option T.int) "shares" (Some 43390383) e.shares;
                T.check (T.option (T.float 0.)) "percent" (Some 9.8) e.percent;
                T.check T.bool "not passive" false e.passive;
                T.check T.bool "is an amendment" true e.is_amendment
              | _ -> T.fail "expected exactly one event");
            T.check T.bool "items prose captured" true (String.length prose > 0));
      ] );
    (
      "parse_13f",
      [
        T.test_case "NVIDIA Q2 2026 cover + table" `Quick (fun () ->
            let f =
              Ownership.parse_13f (fixture "13f_nvda_primary.xml") ~meta:meta_13f
                ~form:"13F-HR" (Some (fixture "13f_nvda_table.xml"))
            in
            T.check T.string "filer_cik" "0001045810" f.filer_cik;
            T.check T.string "filer_name" "NVIDIA CORP" f.filer_name;
            T.check T.string "period" "2026-06-30" (Date.to_string f.period);
            T.check T.bool "not an amendment" false f.is_amendment;
            T.check (T.option T.int) "total value" (Some 63439974569)
              f.total_value_usd;
            T.check T.int "eight positions" 8 (List.length f.positions);
            ( match f.positions with
              | first :: _ ->
                T.check T.string "first issuer" "COHERENT CORP" first.issuer_name;
                T.check (T.option T.int) "first value" (Some 3072195870)
                  first.value_usd;
                T.check (T.option T.int) "first shares" (Some 7788161) first.shares;
                T.check T.string "prnamt" "SH" first.prnamt_type;
                T.check (T.option T.int) "vote sole" (Some 7788161) first.vote_sole
              | [] -> T.fail "no positions"));
        T.test_case "missing information table -> zero positions" `Quick (fun () ->
            let f =
              Ownership.parse_13f (fixture "13f_nvda_primary.xml") ~meta:meta_13f
                ~form:"13F-HR" None
            in
            T.check T.int "no positions" 0 (List.length f.positions);
            T.check (T.option T.int) "total still parsed" (Some 63439974569)
              f.total_value_usd);
      ] );
  ]
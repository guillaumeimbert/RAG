module T = Alcotest.V1
module F = Test_fixtures

let tests : (string * unit T.test_case list) list =
  [
    (
      "business_days",
      [
        T.test_case "skips the weekend" `Quick (fun () ->
            T.check (T.list T.string) "mismatch" [ "2025-08-18"; "2025-08-19"; "2025-08-20" ] (Pipeline.business_days (Date.of_string "2025-08-16") (Date.of_string "2025-08-20")
                 |> List.map Date.to_string));
        T.test_case "single day" `Quick (fun () ->
            T.check (T.list T.string) "mismatch" [ "2025-08-18" ] (Pipeline.business_days (Date.of_string "2025-08-18") (Date.of_string "2025-08-18")
                 |> List.map Date.to_string));
        T.test_case "weekend only -> empty" `Quick (fun () ->
            T.check (T.list T.string) "mismatch" [] (Pipeline.business_days (Date.of_string "2025-08-16") (Date.of_string "2025-08-17")
                 |> List.map Date.to_string));
        T.test_case "crosses a month" `Quick (fun () ->
            T.check (T.list T.string) "mismatch" [ "2025-08-29"; "2025-09-01"; "2025-09-02" ] (Pipeline.business_days (Date.of_string "2025-08-29") (Date.of_string "2025-09-02")
                 |> List.map Date.to_string));
      ] );
    (
      "jobs_of_submissions",
      [
        T.test_case "real NVDA submissions (trimmed)" `Quick (fun () ->
            let cfg = F.cfg_for "https://www.sec.gov" (fun c -> c) in
            let j = Yojson.Safe.from_string (F.read_text (F.fix "nvda_submissions.json")) in
            let jobs = Pipeline.jobs_of_submissions cfg j in
            T.check T.int "mismatch" 5 (List.length jobs);  (* the 6th fixture row has no document *)
            let j0 = List.hd jobs in
            T.check T.string "mismatch" "8-K" j0.Pipeline.index.Edgar.form;
            T.check T.string "mismatch" "0001045810" j0.Pipeline.index.Edgar.cik;
            T.check T.string "mismatch" "NVIDIA CORP" j0.Pipeline.index.Edgar.company;
            T.check T.string "mismatch" "NVDA" j0.Pipeline.index.Edgar.ticker;
            T.check T.string "mismatch" "nvda-20260817.htm" j0.Pipeline.index.Edgar.primary_document;
            T.check T.string "mismatch" "2026-08-17" (Date.to_string j0.Pipeline.index.Edgar.filed_at);
            (* unpadded cik in the archives path *)
            T.check T.string "mismatch" "https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000069-index.htm" j0.Pipeline.index.Edgar.index_url;
            (* primary_url points at the undashed accession directory *)
            T.check T.string "mismatch" "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000069/nvda-20260817.htm" j0.Pipeline.primary_url;
            (* non-10-K forms pass through and are filtered later by [Config.forms] *)
            T.check (T.list T.string) "mismatch" [ "8-K"; "13F-HR"; "4"; "4"; "SCHEDULE 13G" ] (List.map (fun j -> j.Pipeline.index.Edgar.form) jobs));
        T.test_case "bad dates are dropped" `Quick (fun () ->
            let cfg = F.cfg_for "https://www.sec.gov" (fun c -> c) in
            let j =
              Yojson.Safe.from_string
                "{\"name\": \"X\", \"cik\": \"1\", \"tickers\": [\"X\"], \"filings\": {\"recent\": {\"accessionNumber\": [\"0000000001-25-000001\"], \"form\": [\"10-K\"], \"filingDate\": [\"not-a-date\"], \"primaryDocument\": [\"x.htm\"]}}}"
            in
            T.check (T.list T.string) "mismatch" [] (Pipeline.jobs_of_submissions cfg j |> List.map (fun _ -> "")));
      ] );
    (
      "show_stats",
      [
        T.test_case "formats" `Quick (fun () ->
            T.check T.string "mismatch" "docs=2 chunks=10 events=3 positions=4 skipped=1"
              (Pipeline.show_stats { Pipeline.docs = 2; chunks = 10; skipped = 1; events = 3; positions = 4 }));
      ] );
  ]
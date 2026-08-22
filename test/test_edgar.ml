module T = Alcotest.V1
module F = Test_fixtures


let tests : (string * unit T.test_case list) list =
  [
    (
      "parse_sitemap",
      [
        T.test_case "fixture pins the format" `Quick (fun () ->
            (* fixture: 5 <loc> entries — one https, one duplicate, one that is a
               document URL (no -index.htm) and must be ignored *)
            let fs = Gz.gunzip (F.read_bin (F.fix "sitemap.xml.gz")) |> Edgar.parse_sitemap in
            T.check T.int "mismatch" 3 (List.length fs);
            T.check (T.list (T.pair T.string T.string)) "mismatch" [
                ("0001045810-26-000021", "1045810");
                ("0000320193-25-000079", "320193");
                ("0000804328-25-000114", "804328");
              ] (List.map (fun (f : Edgar.filing) -> (f.accession, f.cik)) fs);
            T.check (T.list T.string) "mismatch" [
                "https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000021-index.htm";
                "https://www.sec.gov/Archives/edgar/data/320193/0000320193-25-000079-index.htm";
                "https://www.sec.gov/Archives/edgar/data/804328/0000804328-25-000114-index.htm";
              ] (List.map (fun (f : Edgar.filing) -> f.index_url) fs);
            (* http:// entries were upgraded to https:// *)
            T.check T.bool "https urls" true (List.for_all (fun u -> String.starts_with u ~prefix:"https://")
                       (List.map (fun (f : Edgar.filing) -> f.index_url) fs)));
        T.test_case "empty document" `Quick (fun () ->
            T.check (T.list T.string) "mismatch" [] (Edgar.parse_sitemap "" |> List.map (fun (f : Edgar.filing) -> f.accession)) );
        T.test_case "no matching entries" `Quick (fun () ->
            T.check (T.list T.string) "mismatch" [] (Edgar.parse_sitemap "<urlset></urlset>" |> List.map (fun (f : Edgar.filing) -> f.accession)) );
      ] );
    (
      "find_cik",
      [
        T.test_case "fixture pins the format" `Quick (fun () ->
            let j = Yojson.Safe.from_string (F.read_text (F.fix "company_tickers.json")) in
            T.check (T.option T.string) "mismatch" (Some "0001045810") (Edgar.find_cik j "NVDA");
            T.check (T.option T.string) "mismatch" (Some "0001045810") (Edgar.find_cik j "nvda");
            T.check (T.option T.string) "mismatch" (Some "0000320193") (Edgar.find_cik j "AAPL");
            T.check (T.option T.string) "mismatch" (Some "0000804328") (Edgar.find_cik j "msft");
            (* row without a "ticker" field must not break the scan *)
            T.check (T.option T.string) "mismatch" None (Edgar.find_cik j "NOPE"));
        T.test_case "non-object raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.expecting_pred (fun () -> ignore (Edgar.find_cik (`List []) "NVDA")));
      ] );
    (
      "pad_cik",
      [
        T.test_case "pads to 10" `Quick (fun () ->
            T.check T.string "mismatch" "0001045810" (Edgar.pad_cik "1045810"));
        T.test_case "keeps 10" `Quick (fun () ->
            T.check T.string "mismatch" "0001045810" (Edgar.pad_cik "0001045810"));
        T.test_case "keeps >10" `Quick (fun () ->
            T.check T.string "mismatch" "12345678901" (Edgar.pad_cik "12345678901"));
      ] );
    (
      "parse_index (real index pages)",
      [
        T.test_case "NVDA 10-K" `Quick (fun () ->
            let filing =
              {
                Edgar.accession = "0001045810-26-000021";
                cik = "1045810";
                index_url =
                  "https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000021-index.htm";
              } in
            let fi =
              match Edgar.parse_index filing (F.read_text (F.fix "nvda_10k_index.html")) with
              | Some fi -> fi
              | None -> raise (Edgar.Failure "parse failed")
            in
            T.check T.string "mismatch" "10-K" fi.Edgar.form;
            T.check T.string "mismatch" "NVIDIA CORP" fi.Edgar.company;
            T.check T.string "mismatch" "2026-02-25" (Date.to_string fi.Edgar.filed_at);
            T.check (T.option T.string) "mismatch" (Some "2026-01-25") (Option.map (fun d -> Date.to_string d) fi.Edgar.report_date);
            T.check T.string "mismatch" "nvda-20260125.htm" fi.Edgar.primary_document;
            T.check T.string "mismatch" "0001045810" fi.Edgar.cik);
        T.test_case "AAPL 10-K (filer spans tags)" `Quick (fun () ->
            let filing =
              {
                Edgar.accession = "0000320193-25-000079";
                cik = "320193";
                index_url =
                  "https://www.sec.gov/Archives/edgar/data/320193/0000320193-25-000079-index.htm";
              } in
            let fi =
              match Edgar.parse_index filing (F.read_text (F.fix "aapl_10k_index.html")) with
              | Some fi -> fi
              | None -> raise (Edgar.Failure "parse failed")
            in
            T.check T.string "mismatch" "10-K" fi.Edgar.form;
            T.check T.string "mismatch" "Apple Inc." fi.Edgar.company;
            T.check T.string "mismatch" "2025-10-31" (Date.to_string fi.Edgar.filed_at);
            T.check T.string "mismatch" "aapl-20250927.htm" fi.Edgar.primary_document);
        T.test_case "garbage page -> None" `Quick (fun () ->
            let filing =
              { Edgar.accession = "x"; cik = "1"; index_url = "http://x" } in
            T.check (T.option T.string) "mismatch" None (Edgar.parse_index filing "<html>nope</html>" |> Option.map (fun fi -> fi.Edgar.form)) );
      ] );
    (
      "primary_url",
      [
        T.test_case "dashed index URL -> undashed document dir" `Quick (fun () ->
            let fi =
              {
                Edgar.accession = "0001045810-26-000021";
                cik = "0001045810";
                company = "NVIDIA CORP";
                form = "10-K";
                filed_at = Date.of_string "2026-02-25";
                report_date = Some (Date.of_string "2026-01-25");
                primary_document = "nvda-20260125.htm";
                primary_description = "10-K";
                index_url =
                  "https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000021-index.htm";
                ticker = "NVDA";
              } in
            T.check T.string "mismatch" "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000021/nvda-20260125.htm" (Edgar.primary_url fi));
      ] );
    (
      "listing_url",
      [
        T.test_case "QTR3 in August" `Quick (fun () ->
            let cfg = F.cfg_for "http://sec" (fun c -> c) in
            T.check T.string "mismatch" "http://sec/20250818/QTR3/sitemap.20250818.xml" (Edgar.listing_url cfg (Date.of_string "2025-08-18")));
        T.test_case "QTR1 in February" `Quick (fun () ->
            let cfg = F.cfg_for "http://sec" (fun c -> c) in
            T.check T.string "mismatch" "http://sec/20250210/QTR1/sitemap.20250210.xml" (Edgar.listing_url cfg (Date.of_string "2025-02-10")));
      ] );
  ]
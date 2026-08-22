module T = Alcotest.V1
module F = Test_fixtures


let tests : (string * unit T.test_case list) list =
  [
    (
      "parse_sitemap",
      [
        T.test_case "real capture pins the live format" `Quick (fun () ->
            (* Real capture of the first 12 entries of
               /Archives/edgar/daily-index/2026/QTR3/sitemap.20260821.xml
               (verified live 2026-08-22). Short-form <loc> URLs (dashed
               accession directly under the unpadded CIK directory),
               http:// (upgraded to https). The endpoint serves identity by
               default and gzip when requested (Accept-Encoding: gzip); the
               .gz fixture is the same capture gzipped, so both encodings
               are pinned. *)
            let fs = F.read_text (F.fix "sitemap.xml") |> Edgar.parse_sitemap in
            T.check T.int "mismatch" 12 (List.length fs);
            T.check (T.list (T.pair T.string T.string)) "mismatch" [
                ("0000000000-24-008189", "2019042");
                ("0000000000-24-013440", "2019042");
                ("0000000000-25-000133", "2019042");
                ("0000000000-25-002933", "2019042");
                ("0000000000-25-003640", "2019042");
                ("0000000000-25-004448", "1083743");
                ("0000000000-25-005511", "2054947");
                ("0000000000-25-005601", "2065601");
                ("0000000000-25-006098", "2044725");
                ("0000000000-25-006155", "2067767");
                ("0000000000-25-006220", "2054947");
                ("0000000000-25-006459", "2063022");
              ] (List.map (fun (f : Edgar.filing) -> (f.accession, f.cik)) fs);
            (* http:// entries were upgraded to https:// *)
            T.check T.bool "https urls" true (List.for_all (fun u -> String.starts_with u ~prefix:"https://")
                       (List.map (fun (f : Edgar.filing) -> f.index_url) fs));
            T.check T.string "short-form index url"
              "https://www.sec.gov/Archives/edgar/data/2019042/0000000000-24-008189-index.htm"
              (List.hd (List.map (fun (f : Edgar.filing) -> f.index_url) fs)));
        T.test_case "gzip-encoded capture parses identically" `Quick (fun () ->
            let fs = Gz.gunzip (F.read_bin (F.fix "sitemap.xml.gz")) |> Edgar.parse_sitemap in
            T.check T.int "mismatch" 12 (List.length fs);
            T.check T.string "mismatch" "0000000000-24-008189"
              (List.hd (List.map (fun (f : Edgar.filing) -> f.accession) fs)));
        T.test_case "duplicates and non-index entries are skipped" `Quick (fun () ->
            let xml =
              "<urlset>"
              ^ "<url><loc>https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000021-index.htm</loc></url>"
              ^ "<url><loc>https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000021-index.htm</loc></url>"
              ^ "<url><loc>https://www.sec.gov/Archives/edgar/data/1045810/000104581026000021/nvda-20260125.htm</loc></url>"
              ^ "</urlset>" in
            let fs = Edgar.parse_sitemap xml in
            T.check (T.list T.string) "mismatch" ["0001045810-26-000021"]
              (List.map (fun (f : Edgar.filing) -> f.accession) fs));
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
        T.test_case "letter/anonymous filing (no form metadata) -> None" `Quick (fun () ->
            (* real capture of a CIK-0 letter filing: same index-page template
               but no form section, no filing date, no HTML documents. A whole
               day of sitemaps contains several of these; they must be skipped,
               not fail the run. *)
            let filing =
              { Edgar.accession = "0000000000-24-008189"; cik = "2019042"; index_url = "http://x" } in
            T.check (T.option T.string) "mismatch" None (Edgar.parse_index filing (F.read_text (F.fix "letter_filing_index.html")) |> Option.map (fun fi -> fi.Edgar.form)) );
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
            (* verified live 2026-08-22: /daily-index/{YYYY}/QTR{q}/sitemap.{YYYYMMDD}.xml
               (the date-first form returns 403) *)
            T.check T.string "mismatch" "http://sec/2025/QTR3/sitemap.20250818.xml" (Edgar.listing_url cfg (Date.of_string "2025-08-18")));
        T.test_case "QTR1 in February" `Quick (fun () ->
            let cfg = F.cfg_for "http://sec" (fun c -> c) in
            T.check T.string "mismatch" "http://sec/2025/QTR1/sitemap.20250210.xml" (Edgar.listing_url cfg (Date.of_string "2025-02-10")));
      ] );
  ]
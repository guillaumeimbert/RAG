module T = Alcotest.V1
module F = Test_fixtures


let tests : (string * unit T.test_case list) list =
  [
    (
      "parse_master",
      [
        T.test_case "fixture pins the live format" `Quick (fun () ->
            (* Real capture of the daily master index format (verified live
               2026-08-22 against master.20260820.idx): five header lines, a
               CIK|Company Name|Form Type|Date Filed|File Name column line, an
               80-dash separator, then pipe-delimited rows whose File Name is
               the canonical archive path {cik}/{accession}.txt. The same
               accession is listed once per related CIK (the last row repeats
               the first). *)
            let rows = F.read_text (F.fix "master.idx") |> Edgar.parse_master in
            T.check T.int "12 rows" 12 (List.length rows);
            let first = List.hd rows in
            T.check T.string "cik" "1045810" first.Edgar.cik;
            T.check T.string "company" "NVIDIA CORP" first.Edgar.company;
            T.check T.string "form_type" "10-K" first.Edgar.form_type;
            T.check T.string "date" "20260820" first.Edgar.date;
            T.check T.string "accession" "0001045810-26-000021" first.Edgar.accession;
            (* the Form Type column is preserved verbatim (normalisation is
               master_filings' job, not the parser's) *)
            let by_acc a = List.find (fun (r : Edgar.master_row) -> r.Edgar.accession = a) rows in
            T.check T.string "SCHEDULE prefix kept" "SCHEDULE 13G" (by_acc "0001045810-26-000062").Edgar.form_type;
            T.check T.string "SC prefix kept" "SC 13D" (by_acc "0000320193-26-000050").Edgar.form_type);
        T.test_case "header, separator and blank lines are skipped" `Quick (fun () ->
            let body =
              "Description:           Daily Index of EDGAR Dissemination Feed\n"
              ^ " \n"
              ^ "CIK|Company Name|Form Type|Date Filed|File Name\n"
              ^ "--------------------------------------------------------------------------------\n"
              ^ "1045810|NVIDIA CORP|10-K|20260820|edgar/data/1045810/0001045810-26-000021.txt" in
            let rows = Edgar.parse_master body in
            T.check T.int "one row" 1 (List.length rows);
            T.check T.string "accession" "0001045810-26-000021" (List.hd rows).Edgar.accession);
        T.test_case "empty document" `Quick (fun () ->
            T.check (T.list T.string) "mismatch" [] (Edgar.parse_master "" |> List.map (fun (r : Edgar.master_row) -> r.Edgar.accession)));
        T.test_case "malformed rows are ignored" `Quick (fun () ->
            let body =
              "not a row\n"
              ^ "1|2\n"
              ^ "12345|CO|10-K|2026|edgar/data/12345/x.txt\n"
              ^ "12345|CO|10-K|20260820|no-slash.txt" in
            T.check (T.list T.string) "mismatch" [] (Edgar.parse_master body |> List.map (fun (r : Edgar.master_row) -> r.Edgar.accession)));
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
               day's master index contains several of these; they must be
               skipped, not fail the run. (With master-index pre-filtering most
               are dropped before the index page is fetched; this path is the
               safety net for the rest. *)
            let filing =
              { Edgar.accession = "0000000000-24-008189"; cik = "2019042"; index_url = "http://x" } in
            T.check (T.option T.string) "mismatch" None (Edgar.parse_index filing (F.read_text (F.fix "letter_filing_index.html")) |> Option.map (fun fi -> fi.Edgar.form)) );
        T.test_case "13G index page (form with a space, no information table)" `Quick (fun () ->
            let filing =
              {
                Edgar.accession = "0001045810-26-000062";
                cik = "1045810";
                index_url =
                  "https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000062-index.htm";
              } in
            let fi =
              match Edgar.parse_index filing (F.read_text (F.fix "13g_index.html")) with
              | Some fi -> fi
              | None -> raise (Edgar.Failure "parse failed")
            in
            (* the form code contains a space: the old regex stopped at the
               first space ("SCHEDULE") and dropped the whole filing. *)
            T.check T.string "form" "SCHEDULE 13G" fi.Edgar.form;
            T.check (T.option T.string) "info table" None fi.Edgar.info_table_document;
            (* the index lists a .html twin first, but the data is the .xml; the
               parser must pick the .xml, not the .html. *)
            T.check T.string "primary document" "primary_doc.xml" fi.Edgar.primary_document;
            T.check T.string "company" "NVIDIA CORP" fi.Edgar.company);
        T.test_case "13F index page (information table filename from the index)" `Quick (fun () ->
            let filing =
              {
                Edgar.accession = "0001045810-26-000065";
                cik = "1045810";
                index_url =
                  "https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000065-index.htm";
              } in
            let fi =
              match Edgar.parse_index filing (F.read_text (F.fix "13f_index.html")) with
              | Some fi -> fi
              | None -> raise (Edgar.Failure "parse failed")
            in
            (* the information table is named in the index ("infotable.xml"),
               not the assumed "information_table.xml"; the .html twin is not
               the data file. *)
            T.check T.string "form" "13F-HR" fi.Edgar.form;
            T.check (T.option T.string) "info table" (Some "infotable.xml") fi.Edgar.info_table_document;
            (* the .html twin is listed first; the data is the .xml. *)
            T.check T.string "primary document" "primary_doc.xml" fi.Edgar.primary_document);
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
                info_table_document = None;
                index_url =
                  "https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000021-index.htm";
                ticker = "NVDA";
              } in
            T.check T.string "mismatch" "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000021/nvda-20260125.htm" (Edgar.primary_url fi));
      ] );
    (
      "info_table_url",
      [
        T.test_case "uses the information table named in the index" `Quick (fun () ->
            let fi =
              {
                Edgar.accession = "0001045810-26-000065";
                cik = "0001045810";
                company = "NVIDIA CORP";
                form = "13F-HR";
                filed_at = Date.of_string "2026-08-20";
                report_date = Some (Date.of_string "2026-06-30");
                primary_document = "primary_doc.xml";
                primary_description = "";
                info_table_document = Some "infotable.xml";
                index_url =
                  "https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000065-index.htm";
                ticker = "NVDA";
              } in
            T.check T.string "mismatch" "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000065/infotable.xml" (Edgar.info_table_url fi));
        T.test_case "falls back to information_table.xml when the index names none" `Quick (fun () ->
            let fi =
              {
                Edgar.accession = "0001045810-26-000065";
                cik = "0001045810";
                company = "NVIDIA CORP";
                form = "13F-HR";
                filed_at = Date.of_string "2026-08-20";
                report_date = Some (Date.of_string "2026-06-30");
                primary_document = "primary_doc.xml";
                primary_description = "";
                info_table_document = None;
                index_url =
                  "https://www.sec.gov/Archives/edgar/data/1045810/0001045810-26-000065-index.htm";
                ticker = "NVDA";
              } in
            T.check T.string "mismatch" "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000065/information_table.xml" (Edgar.info_table_url fi));
      ] );
    (
      "master_url",
      [
        T.test_case "QTR3 in August" `Quick (fun () ->
            let cfg = F.cfg_for "http://sec" (fun c -> c) in
            (* verified live 2026-08-22: /daily-index/{YYYY}/QTR{q}/master.{YYYYMMDD}.idx *)
            T.check T.string "mismatch" "http://sec/2025/QTR3/master.20250818.idx" (Edgar.master_url cfg (Date.of_string "2025-08-18")));
        T.test_case "QTR1 in February" `Quick (fun () ->
            let cfg = F.cfg_for "http://sec" (fun c -> c) in
            T.check T.string "mismatch" "http://sec/2025/QTR1/master.20250210.idx" (Edgar.master_url cfg (Date.of_string "2025-02-10")));
      ] );
    (
      "master_filings",
      [
        T.test_case "filters by cfg forms and dedupes by accession" `Quick (fun () ->
            let cfg = F.cfg_for "http://sec" (fun c -> { c with Config.forms = ["10-K"; "10-K/A"; "8-K"; "13G"] }) in
            let rows = F.read_text (F.fix "master.idx") |> Edgar.parse_master in
            let fs = Edgar.master_filings cfg rows in
            T.check (T.list T.string) "accessions (first-occurrence order, deduped)"
              ["0001045810-26-000021"; "0000320193-25-000079"; "0001045810-26-000100"; "0001045810-26-000062"]
              (List.map (fun (f : Edgar.filing) -> f.Edgar.accession) fs);
            T.check T.string "index url" "http://sec/Archives/edgar/data/1045810/0001045810-26-000021-index.htm"
              (List.hd (List.map (fun (f : Edgar.filing) -> f.Edgar.index_url) fs)));
        T.test_case "ALL keeps every unique accession" `Quick (fun () ->
            let cfg = F.cfg_for "http://sec" (fun c -> { c with Config.forms = ["ALL"] }) in
            let rows = F.read_text (F.fix "master.idx") |> Edgar.parse_master in
            T.check T.int "11 unique accessions (12 rows minus 1 duplicate)" 11 (List.length (Edgar.master_filings cfg rows)));
        T.test_case "no matching form -> empty" `Quick (fun () ->
            let cfg = F.cfg_for "http://sec" (fun c -> { c with Config.forms = ["20-F"] }) in
            let rows = F.read_text (F.fix "master.idx") |> Edgar.parse_master in
            T.check T.int "none" 0 (List.length (Edgar.master_filings cfg rows)));
      ] );
  ]

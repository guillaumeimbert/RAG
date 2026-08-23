(** Scratch: live probe for the ownership (13G/13D/13F) ingest path.
    Fetches real EDGAR XML for the NVIDIA Nebius 13G and one 13F-HR and
    prints what the parsers extract. Not part of the test suite. *)

let () =
  let cfg = Config.load () in
  let get (u : string) =
    Lwt.bind (Edgar.get_document cfg u) (fun s ->
      Printf.printf "fetched %s (%d bytes)\n%!" u (String.length s);
      Lwt.return s)
  in
  let l3g =
    "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000062/primary_doc.xml"
  in
  let l13f =
    "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000065/primary_doc.xml"
  in
  let table =
    "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000065/information_table.xml"
  in
  let meta13g =
    { Ownership.accession = "0001045810-26-000062"
    ; filed_at = Date.of_string "2026-07-20"
    ; index_url = ""
    }
  in
  let meta13f =
    { Ownership.accession = "0001045810-26-000065"
    ; filed_at = Date.of_string "2026-08-14"
    ; index_url = ""
    }
  in
  Lwt_main.run
    (Lwt.bind (get l3g) (fun s ->
       Lwt.bind (get l13f) (fun primary ->
         Lwt.bind (get table) (fun tbl ->
           let (events, prose) = Ownership.parse_13g s ~meta:meta13g ~form:"SCHEDULE 13G" in
           let e = List.hd events in
           Printf.printf
             "13G: %s -> %s (%.2f%%, %d shares, passive=%b, %d prose chars)\n%!"
             e.filer_name e.subject_name
             (Option.value ~default:(-1.) e.percent)
             (Option.value ~default:0 e.shares)
             e.passive
             (String.length prose);
           let f = Ownership.parse_13f primary ~meta:meta13f ~form:"13F-HR" (Some tbl) in
           Printf.printf
             "13F: %s, total $%d, %d positions\n%!"
             f.filer_name
             (Option.value ~default:0 f.total_value_usd)
             (List.length f.positions);
           Lwt.return_unit))))
(** Unit tests. The heavy end-to-end flow lives in [e2e]. *)

let () =
  Alcotest.run "raguesslighter"
    ( Test_stringx.tests
    @ Test_date.tests
    @ Test_chunk.tests
    @ Test_json.tests
    @ Test_config.tests
    @ Test_gz.tests
    @ Test_edgar.tests
    @ Test_openai.tests
    @ Test_pipeline.tests
    @ Test_html_text.tests
    @ Test_net.tests
    @ Test_xml.tests
    @ Test_ownership.tests )
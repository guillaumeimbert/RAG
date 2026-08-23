(** Unit tests for the minimal XML walker ([Xml]). *)

module T = Alcotest.V1

let parse s = Xml.parse s

let text (n : Xml.node) : string =
  match n with
  | Xml.Text s -> s
  | _ -> failwith "expected a text node"

let only : Xml.node list -> Xml.node = function
  | [ n ] -> n
  | [] -> failwith "expected exactly one node"
  | _ -> failwith "expected exactly one node"

(** [first_text children] = text of the first text child. *)
let first_text (children : Xml.node list) : string =
  match children with
  | Xml.Text t :: _ -> t
  | _ -> failwith "expected a text child"

let tests : (string * unit T.test_case list) list =
  [
    (
      "local_name",
      [
        T.test_case "strips the namespace prefix" `Quick (fun () ->
            T.check T.string "mismatch" "element" (Xml.local_name "sch:element"));
        T.test_case "plain names untouched" `Quick (fun () ->
            T.check T.string "mismatch" "root" (Xml.local_name "root"));
      ] );
    (
      "parse",
      [
        T.test_case "element with text" `Quick (fun () ->
            ( match parse "<a>hello</a>" with
              | [ Xml.Elem e ] -> T.check T.string "mismatch" "hello" (first_text e.children)
              | _ -> T.fail "expected one element" ));
        T.test_case "nested elements" `Quick (fun () ->
            let e = only (parse "<a><b>1</b><b>2</b></a>") in
            ( match e with
              | Xml.Elem el ->
                ( match el.children with
                  | [ Xml.Elem b1; Xml.Elem b2 ] ->
                    T.check T.string "b1" "1" (first_text b1.children);
                    T.check T.string "b2" "2" (first_text b2.children)
                  | _ -> T.fail "expected two b children")
              | _ -> T.fail "expected an element"));
        T.test_case "namespaced elements, prefixes stripped" `Quick (fun () ->
            let e = only (parse "<sch:root><sch:cik>123</sch:cik></sch:root>") in
            ( match e with
              | Xml.Elem el ->
                T.check T.string "name" "root" el.name;
                T.check (T.option T.string) "cik" (Some "123")
                  (Xml.child_text "cik" e)
              | _ -> T.fail "expected an element"));
        T.test_case "prolog, DOCTYPE and comments are skipped" `Quick (fun () ->
            let e =
              only
                (parse "<?xml version=\"1.0\"?><!DOCTYPE x><a><!-- c --><b>y</b></a>")
            in
            ( match e with
              | Xml.Elem el ->
                ( match el.children with
                  | [ Xml.Elem b ] -> T.check T.string "b" "y" (first_text b.children)
                  | _ -> T.fail "expected a b element")
              | _ -> T.fail "expected an element"));
        T.test_case "named and numeric entities are decoded" `Quick (fun () ->
            let e = only (parse "<a>&amp;&lt;b&gt;&#65;</a>") in
            ( match e with
              | Xml.Elem el -> T.check T.string "text" "&<b>A" (first_text el.children)
              | _ -> T.fail "expected an element"));
        T.test_case "attributes are ignored but tolerated" `Quick (fun () ->
            let e = only (parse "<a x=\"1\" y='2'>t</a>") in
            ( match e with
              | Xml.Elem el -> T.check T.string "text" "t" (first_text el.children)
              | _ -> T.fail "expected an element"));
        T.test_case "mixed text and elements" `Quick (fun () ->
            let e = only (parse "<a>pre<b>m</b>post</a>") in
            ( match e with
              | Xml.Elem el ->
                ( match el.children with
                  | [ Xml.Text pre; Xml.Elem b; Xml.Text post ] ->
                    T.check T.string "pre" "pre" pre;
                    T.check T.string "m" "m" (first_text b.children);
                    T.check T.string "post" "post" post
                  | _ -> T.fail "bad children")
              | _ -> T.fail "expected an element"));
      ] );
    (
      "queries",
      [
        T.test_case "elem finds the first match" `Quick (fun () ->
            let r = only (parse "<r><a>1</a><b>2</b><a>3</a></r>") in
            ( match Xml.elem "a" r with
              | Some (Xml.Elem e) -> T.check T.string "first a" "1" (first_text e.children)
              | _ -> T.fail "a not found"));
        T.test_case "elems collects all matches in order" `Quick (fun () ->
            let r = only (parse "<r><a>1</a><b>2</b><a>3</a></r>") in
            T.check (T.list T.string) "mismatch" ["1"; "3"]
              (Xml.elems "a" r |> List.map (fun e ->
                   match e with Xml.Elem el -> first_text el.children | _ -> "")));
        T.test_case "path follows the name sequence" `Quick (fun () ->
            let r = only (parse "<r><a><b><c>deep</c></b></a></r>") in
            T.check (T.option T.string) "mismatch" (Some "deep")
              (Xml.path_text [ "a"; "b"; "c" ] r));
        T.test_case "path fails when a segment is missing" `Quick (fun () ->
            let r = only (parse "<r><a><b>shallow</b></a></r>") in
            T.check (T.option T.string) "mismatch" None
              (Xml.path_text [ "a"; "b"; "c" ] r));
        T.test_case "text_of concatenates descendant text" `Quick (fun () ->
            let e = only (parse "<a>x<b>y</b>z</a>") in
            T.check T.string "mismatch" "x y z" (Xml.text_of e));
      ] );
    (
      "errors",
      [
        T.test_case "unclosed element raises Parse_error" `Quick (fun () ->
            T.match_raises "raises" Tcheck.xml_parse_error_pred (fun () ->
                ignore (parse "<a><b></a>")));
        T.test_case "stray closing tag raises Parse_error" `Quick (fun () ->
            T.match_raises "raises" Tcheck.xml_parse_error_pred (fun () ->
                ignore (parse "<a></b>")));
        T.test_case "trailing text after the root raises" `Quick (fun () ->
            T.match_raises "raises" Tcheck.xml_parse_error_pred (fun () ->
                ignore (parse "<a>1</a>stray")));
      ] );
  ]
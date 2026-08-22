module T = Alcotest.V1

let d y m day = { Date.year = y; month = m; day }

let tests : (string * unit T.test_case list) list =
  [
    (
      "to_string",
      [
        T.test_case "full" `Quick (fun () ->
            T.check T.string "mismatch" "2025-08-18" (Date.to_string (d 2025 8 18)));
        T.test_case "zero padding" `Quick (fun () ->
            T.check T.string "mismatch" "1999-01-02" (Date.to_string (d 1999 1 2)));
      ] );
    (
      "of_string",
      [
        T.test_case "round-trips" `Quick (fun () ->
            T.check (T.option T.string) "mismatch" (Some "2025-08-18") (let d_ = Date.of_string "2025-08-18" in
                Some (Date.to_string d_)));
        T.test_case "rejects embedded garbage (anchored)" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_string "xx2025-01-15yy"));
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_string "2025-01-15T00:00:00")));
        T.test_case "rejects unseparated" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_string "20250818")));
        T.test_case "rejects single-digit fields" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_string "2025-1-15")));
        T.test_case "rejects month 13" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_string "2025-13-01")));
        T.test_case "rejects day 0" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_string "2025-01-00")));
        T.test_case "rejects Feb 30" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_string "2025-02-30")));
        T.test_case "rejects empty" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_string "")));
        T.test_case "leap day 2024" `Quick (fun () ->
            T.check T.int "mismatch" 29 (Date.of_string "2024-02-29").Date.day);
        T.test_case "rejects Feb 29 2025" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_string "2025-02-29")));
        T.test_case "rejects Feb 29 1900 (century, not leap)" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_string "1900-02-29")));
        T.test_case "accepts Feb 29 2000 (400-year leap)" `Quick (fun () ->
            T.check T.int "mismatch" 2 (Date.of_string "2000-02-29").Date.month);
      ] );
    (
      "of_yyyymmdd",
      [
        T.test_case "parses" `Quick (fun () ->
            T.check T.string "mismatch" "2025-08-18" (Date.to_string (Date.of_yyyymmdd "20250818")));
        T.test_case "rejects 7 chars" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_yyyymmdd "2025818")));
        T.test_case "rejects 9 chars" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_yyyymmdd "202508181")));
        T.test_case "validates the date" `Quick (fun () ->
            T.match_raises "raises" Tcheck.failure_pred (fun () -> ignore (Date.of_yyyymmdd "20250230")));
      ] );
    (
      "quarter",
      [
        T.test_case "Jan -> 1" `Quick (fun () -> T.check T.int "mismatch" 1 (Date.quarter (d 2025 1 15)));
        T.test_case "Mar -> 1" `Quick (fun () -> T.check T.int "mismatch" 1 (Date.quarter (d 2025 3 31)));
        T.test_case "Apr -> 2" `Quick (fun () -> T.check T.int "mismatch" 2 (Date.quarter (d 2025 4 1)));
        T.test_case "Aug -> 3" `Quick (fun () -> T.check T.int "mismatch" 3 (Date.quarter (d 2025 8 18)));
        T.test_case "Dec -> 4" `Quick (fun () -> T.check T.int "mismatch" 4 (Date.quarter (d 2025 12 1)));
      ] );
    (
      "weekday",
      [
        T.test_case "1970-01-01 was a Thursday" `Quick (fun () ->
            T.check T.int "mismatch" 3 (Date.weekday (d 1970 1 1)));
        T.test_case "2025-11-27 (Thanksgiving) is a Thursday" `Quick (fun () ->
            T.check T.int "mismatch" 3 (Date.weekday (d 2025 11 27)));
        T.test_case "2025-08-16 is a Saturday" `Quick (fun () ->
            T.check T.int "mismatch" 5 (Date.weekday (d 2025 8 16)));
        T.test_case "2025-08-18 is a Monday" `Quick (fun () ->
            T.check T.int "mismatch" 0 (Date.weekday (d 2025 8 18)));
      ] );
    (
      "is_weekend / prev_business_day",
      [
        T.test_case "Saturday is weekend" `Quick (fun () ->
            T.check T.bool "mismatch" true (Date.is_weekend (d 2025 8 16)));
        T.test_case "Monday is not" `Quick (fun () ->
            T.check T.bool "mismatch" false (Date.is_weekend (d 2025 8 18)));
        T.test_case "Saturday -> Friday" `Quick (fun () ->
            T.check T.string "mismatch" "2025-08-15" (Date.to_string (Date.prev_business_day (d 2025 8 16))));
        T.test_case "Sunday -> Friday" `Quick (fun () ->
            T.check T.string "mismatch" "2025-08-15" (Date.to_string (Date.prev_business_day (d 2025 8 17))));
        T.test_case "weekday stays" `Quick (fun () ->
            T.check T.string "mismatch" "2025-08-18" (Date.to_string (Date.prev_business_day (d 2025 8 18))));
      ] );
    (
      "add_days",
      [
        T.test_case "month rollover" `Quick (fun () ->
            T.check T.string "mismatch" "2025-02-01" (Date.to_string (Date.add_days (d 2025 1 31) 1)));
        T.test_case "leap year Feb" `Quick (fun () ->
            T.check T.string "mismatch" "2024-02-29" (Date.to_string (Date.add_days (d 2024 2 28) 1)));
        T.test_case "non-leap Feb" `Quick (fun () ->
            T.check T.string "mismatch" "2023-03-01" (Date.to_string (Date.add_days (d 2023 2 28) 1)));
        T.test_case "year rollover" `Quick (fun () ->
            T.check T.string "mismatch" "2026-01-01" (Date.to_string (Date.add_days (d 2025 12 31) 1)));
        T.test_case "backwards across year" `Quick (fun () ->
            T.check T.string "mismatch" "2024-12-31" (Date.to_string (Date.add_days (d 2025 1 1) (-1))));
        T.test_case "zero is identity" `Quick (fun () ->
            T.check T.string "mismatch" "2025-08-18" (Date.to_string (Date.add_days (d 2025 8 18) 0)));
        T.test_case "next" `Quick (fun () ->
            T.check T.string "mismatch" "2025-03-01" (Date.to_string (Date.next (d 2025 2 28))));
      ] );
  ]
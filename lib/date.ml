(** Minimal calendar date helpers (proleptic Gregorian, no external
    dependency). Enough for daily-index discovery: YYYY-MM-DD parsing,
    weekday computation, stepping and quarter arithmetic. *)

type t = { year : int; month : int; day : int }

let is_leap y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0

let days_in_month y m =
  match m with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if is_leap y then 29 else 28
  | _ -> 0

(** Parse a YYYY-MM-DD string. Raises [Failure] on invalid input. *)
let of_string s =
  let m = Re.exec_opt (Re.Pcre.regexp "^(\\d{4})-(\\d{2})-(\\d{2})$") s in
  match m with
  | None -> failwith ("invalid date (expected YYYY-MM-DD): " ^ s)
  | Some m ->
    let year = int_of_string (Re.Group.get m 1) in
    let month = int_of_string (Re.Group.get m 2) in
    let day = int_of_string (Re.Group.get m 3) in
    if month < 1 || month > 12 || day < 1 || day > days_in_month year month
    then failwith ("invalid date: " ^ s)
    else { year; month; day }

(** Parse an unseparated YYYYMMDD string (daily-index sitemap names). *)
let of_yyyymmdd s =
  if String.length s <> 8 then failwith ("invalid YYYYMMDD date: " ^ s)
  else
    of_string
      (String.sub s 0 4 ^ "-" ^ String.sub s 4 2 ^ "-" ^ String.sub s 6 2)

let to_string { year; month; day } =
  Printf.sprintf "%04d-%02d-%02d" year month day

(** Calendar quarter (1..4): QTR1 = Jan-Mar, ..., QTR4 = Oct-Dec. *)
let quarter { month; _ } = (month - 1) / 3 + 1

(** Day of week: 0 = Monday ... 6 = Sunday. *)
let weekday { year; month; day } =
  (* days since 1970-01-01 (Howard Hinnant's civil-from-days algorithm) *)
  let y = if month <= 2 then year - 1 else year in
  let era = if y >= 0 then y / 400 else (y - 399) / 400 in
  let yoe = y - era * 400 in
  let doy = (153 * (month + if month <= 2 then 9 else -3) + 2) / 5 + day - 1 in
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy in
  let days = era * 146097 + doe - 719468 in
  (* 1970-01-01 was a Thursday; Thursday = 3 with Monday = 0. *)
  ((days + 3) mod 7 + 7) mod 7

let is_weekend d = weekday d >= 5

let add_days d n =
  let year = ref d.year in
  let month = ref d.month in
  let day = ref d.day in
  let n = ref n in
  while !n <> 0 do
    if !n > 0 then
      (
        incr day;
        if !day > days_in_month !year !month
        then
          (
            day := 1;
            incr month;
            if !month > 12 then (month := 1; incr year)))
    else
      (
        decr day;
        if !day < 1
        then
          (
            decr month;
            if !month < 1 then (month := 12; decr year);
            day := days_in_month !year !month));
    n := !n - (if !n > 0 then 1 else - 1)
  done;
  { year = !year; month = !month; day = !day }

let next d = add_days d 1

(** Previous business day (skips weekends). *)
let prev_business_day d =
  let rec go x = if is_weekend x then go (add_days x (-1)) else x in
  go d

let today () =
  let tm = Unix.localtime (Unix.time ()) in
  { year = tm.tm_year + 1900; month = tm.tm_mon + 1; day = tm.tm_mday }
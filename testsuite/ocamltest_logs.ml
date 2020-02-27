(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                  Guillaume Bury, OCamlPRo                              *)
(*                                                                        *)
(*   Copyright 2020 OCamlPro SAS                                          *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

type mode =
  | No_mode
  | Skipped_tests
  | Empty_tests
  | Failed_tests
  | Unexpected_errors

let read_file_and_output filename =
  let ch = open_in filename in
  try
    while true do
      let s = input_line ch in
      Printf.printf "%s\n" s
    done
  with End_of_file -> ()

let rec split_last acc = function
  | [] -> assert false
  | [x] -> List.rev acc, x
  | x :: r -> split_last (x :: acc) r

let remove_quotes_and_ext s =
  assert (s.[0] = '\'' && s.[String.length s - 1] = '\'');
  let s' = String.sub s 1 (String.length s - 2) in
  Filename.chop_extension s'

let make_path components = List.fold_left Filename.concat "" components

let files_to_print path test =
  let rec aux acc h =
    match Unix.readdir h with
    | exception End_of_file -> acc
    | s ->
      begin match Filename.extension s with
        | ".log" | ".output" ->
          aux (Filename.concat path s :: acc) h
        | _ -> aux acc h
      end
  in
  aux [] (Unix.opendir path)
  (* [ make_path [path; Format.asprintf "%s.log" test] ] *)

let print_logs s =
  (* Determine path to ocamltest directory for the test *)
  let f = List.hd (String.split_on_char ' ' s) in
  let l = String.split_on_char '/' f in
  let path_l, test_name = split_last [] l in
  let test_name = remove_quotes_and_ext test_name in
  let path_s = make_path path_l in
  let directory_path =
    make_path [path_s; "_ocamltest"; path_s; test_name]
  in
  (* Determine the files to print *)
  let files = files_to_print directory_path test_name in
  (* Print some log + the files *)
  let sep = String.make 80 '#' in
  Format.printf "%s@\n%s@\n@." sep sep;
  List.iter (fun file ->
      Format.printf "### LOG '%s' ###@\n@." file;
      read_file_and_output file;
      Format.printf "@\n## END LOG ###@\n@."
    ) files

let dispatch s = function
  | Failed_tests
  | Unexpected_errors -> print_logs s
  | _ -> ()

let rec read_and_dispatch mode =
  match input_line stdin with
  | exception End_of_file -> ()
  | "" -> read_and_dispatch mode
  | s ->
      if s.[0] = ' ' then begin
        dispatch (String.trim s) mode;
        read_and_dispatch mode
      end else begin
        match String.split_on_char ' ' (String.trim s) with
        | "Summary:" :: _ -> ()
        | "List" :: "of" :: x :: _ ->
            let new_mode = match x with
              | "skipped" -> Skipped_tests
              | "directories" -> Empty_tests
              | "failed" -> Failed_tests
              | "unexpected" -> Unexpected_errors
              | _ -> assert false
            in
            read_and_dispatch new_mode
        | _ ->
            Format.printf "Unknown line:@\n%s@." s;
            assert false
      end

let () =
  read_and_dispatch No_mode


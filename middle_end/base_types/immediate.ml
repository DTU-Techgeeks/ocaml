(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2017 OCamlPro SAS                                    *)
(*   Copyright 2014--2017 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-30-40-41-42"]

module TO = Targetint.OCaml

type 'a or_wrong =
  | Ok of 'a
  | Wrong

type t = {
  value : TO.t;
  print_as_char : bool;
}

type immediate = t

include Identifiable.Make (struct
  type nonrec t = t

  let compare t1 t2 = TO.compare t1.value t2.value

  let equal t1 t2 = TO.equal t1.value t2.value

  let hash t = TO.hash t.value

  let print ppf t =
    let print_as_char =
      t.print_as_char
        && TO.compare t.value TO.zero >= 0
        && TO.compare t.value TO.hex_ff <= 0
    in
    if print_as_char then
      Format.fprintf ppf "(immediate '%c')"
        (Char.chr (TO.bottom_byte_to_int t.value))
    else
      Format.fprintf ppf "(immediate %a)"
        TO.print t.value
end)

let join t1 t2 : t or_wrong =
  if not (TO.equal t1.value t2.value) then
    Wrong
  else
    let print_as_char = t1.print_as_char && t2.print_as_char in
    Ok {
      value = t1.value;
      print_as_char;
    }

let join_set t1s t2s =
  let only_in_t2s = Set.diff t2s t1s in
  let join =
    Set.fold (fun t1 result ->
        match Set.find t1 t2s with
        | exception Not_found -> Set.add t1 result
        | t2 ->
          match join t1 t2 with
          | Wrong -> result
          | Ok t -> Set.add t result)
      t1s
      Set.empty
  in
  Set.union join only_in_t2s

let bool_true = {
  value = TO.one;
  print_as_char = false;
}

let bool_false = {
  value = TO.zero;
  print_as_char = false;
}

let int value = {
  value;
  print_as_char = false;
}

let char value = {
  value = TO.of_char value;
  print_as_char = true;
}

let to_targetint t = t.value

let map t ~f =
  { value = f t.value;
    print_as_char = t.print_as_char;
  }

let set_to_targetint_set set =
  Set.fold (fun t targetints -> TO.Set.add t.value targetints)
    set
    TO.Set.empty

let all_bools =
  Set.of_list [bool_true; bool_false]

module Or_unknown = struct
  type nonrec t =
    | Ok of t
    | Unknown

  let ok imm = Ok imm
  let unknown () = Unknown

  include Identifiable.Make (struct
    type nonrec t = t

    let compare t1 t2 =
      match t1, t2 with
      | Ok _, Unknown -> -1
      | Unknown, Ok _ -> 1
      | Unknown, Unknown -> 0
      | Ok imm1, Ok imm2 -> compare imm1 imm2

    let hash t =
      match t with
      | Ok imm -> Hashtbl.hash (0, hash imm)
      | Unknown -> Hashtbl.hash 1

    let print ppf t =
      match t with
      | Ok imm -> print ppf imm
      | Unknown -> Format.pp_print_string ppf "Unknown"
  end)
end
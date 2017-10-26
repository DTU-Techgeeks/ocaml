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

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

type t = Flambda_kind.t list

let length t = List.length t

include Identifiable.Make (struct
  type nonrec t = t

  let compare t1 t2 = Misc.Stdlib.List.compare Flambda_kind.compare t1 t2
  let equal t1 t2 = (compare t1 t2) = 0
  let hash = Hashtbl.hash

  let print ppf t =
    Format.fprintf ppf "@(%a@)"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf ", ")
        Flambda_kind.print)
      t
end)

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

(** Simplification of the contents of entire compilation units.  These are
    known (maybe somewhat misleadingly) as "programs". *)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

val simplify_program
   : Simplify_env.t
  -> backend:(module Backend_intf.S)
  -> Flambda_static.Program.t
  -> Flambda_static.Program.t

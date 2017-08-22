(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2017 OCamlPro SAS                                          *)
(*   Copyright 2017 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(** Unbox parameters of continuations based on the inferred types at the use
    points of such continuations. *)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

val for_non_recursive_continuation
   : name:Continuation.t
  -> handler:Flambda.Continuation_handler.t
  -> args_types:Flambda_type.t list
  -> backend:(module Backend_intf.S)
  -> Flambda_utils.with_wrapper

val for_recursive_continuations
   : handlers:Flambda.Continuation_handler.ts
  -> args_types:Flambda_type.t list Continuation.Map.t
  -> backend:(module Backend_intf.S)
  -> Flambda_utils.with_wrapper Continuation.Map.t

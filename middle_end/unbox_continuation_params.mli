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

(** Unbox parameters of continuations based on the approximations at the use
    points of such continuations. *)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

val for_non_recursive_continuation
   : name:Continuation.t
  -> handler:Flambda.continuation_handler
  -> args_approxs:Simple_value_approx.t list
  -> backend:(module Backend_intf.S)
  -> Flambda_utils.with_wrapper

val for_recursive_continuations
   : handlers:Flambda.continuation_handlers
  -> args_approxs:Simple_value_approx.t list Continuation.Map.t
  -> backend:(module Backend_intf.S)
  -> Flambda_utils.with_wrapper Continuation.Map.t
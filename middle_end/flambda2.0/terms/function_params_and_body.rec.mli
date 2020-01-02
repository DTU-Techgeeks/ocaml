(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2019 OCamlPro SAS                                    *)
(*   Copyright 2014--2019 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-30-40-41-42"]

(** A name abstraction that comprises a function's parameters (together with
    any relations between them), the code of the function, and the
    [my_closure] variable.  It also includes the return and exception
    continuations.

    From the body of the function, accesses to variables within the closure
    need to go via a [Project_var] (from [my_closure]); accesses to any other
    simultaneously-defined functions need to go likewise via a
    [Select_closure]. *)
type t

(** Printing, invariant checks, name manipulation, etc. *)
include Expr_std.S with type t := t

(** Create an abstraction that binds the given parameters, with associated
    relations thereon, over the given body. *)
val create
   : return_continuation:Continuation.t
  -> Exn_continuation.t
  -> Kinded_parameter.t list
  -> body:Expr.t
  -> my_closure:Variable.t
  -> t

(** Choose a member of the alpha-equivalence class to enable examination
    of the parameters, relations thereon and the body over which they are
    scoped. *)
val pattern_match
   : t
  -> f:(return_continuation:Continuation.t
      (** The continuation parameter of the function, i.e. to where we must
          jump once the result of the function has been computed. If the
          continuation takes more than one argument then the backend will
          compile the function so that it returns multiple values. *)
    -> Exn_continuation.t
      (** To where we must jump if application of the function raises an
          exception. *)
    -> Kinded_parameter.t list
    -> body:Expr.t
    -> my_closure:Variable.t
    -> 'a)
  -> 'a

val params_arity : t -> Flambda_arity.t
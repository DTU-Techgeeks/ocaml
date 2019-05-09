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

module type S = sig
  module Join_env : sig type t end
  module Meet_env : sig type t end
  module Type_equality_env : sig type t end
  module Type_equality_result : sig type t end
  module Typing_env_extension : sig type t end

  type t

  val print : cache:Printing_cache.t -> Format.formatter -> t -> unit

  val equal
     : Type_equality_env.t
    -> Type_equality_result.t
    -> t
    -> t
    -> Type_equality_result.t

  val meet
     : Meet_env.t
    -> t
    -> t
    -> (t * Typing_env_extension.t) Or_bottom.t

  val join
     : Join_env.t
    -> t
    -> t
    -> t

  (** Type algebraic structures are never kept underneath object-language
      binders at present, so we don't include [Contains_names.S]. *)
end
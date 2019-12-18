(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2019 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-30-40-41-42"]

(** Tracking of new versions of code such that it can be determined, for
    any two pieces of code, which one is newer (or that the pieces of code
    are unrelated). *)

type t

val print : Format.formatter -> t -> unit

val empty : t

val add : t -> newer:Code_id.t -> older:Code_id.t -> t

(** [meet] calculates which of the given pieces of code is older, or
    identifies that the pieces of code are unrelated. *)
val meet : t -> Code_id.t -> Code_id.t -> Code_id.t Or_bottom.t

(** [join] calculates which of the given pieces of code is newer, or
    identifies that the pieces of code are unrelated. *)
val join : t -> Code_id.t -> Code_id.t -> Code_id.t Or_unknown.t

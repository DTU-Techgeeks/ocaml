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

module type Env = sig
  (** Environments, following the lexical scope of the program, used during
      simplification.  (See simplify.ml.) *)
  type t

  type result

  val invariant : t -> unit

  (** Create a new environment.  If [never_inline] is true then the returned
      environment will prevent [Simplify] from inlining.  The
      [backend] parameter is used for passing information about the compiler
      backend being used.
      Newly-created environments have inactive [Freshening]s (see below) and do
      not initially hold any approximation information. *)
  val create
     : never_inline:bool
    -> allow_continuation_inlining:bool
    -> allow_continuation_specialisation:bool
    -> round:int
    -> backend:(module Backend_intf.S)
    -> simplify_toplevel:(
         t
      -> result
      -> Flambda.Expr.t
      -> continuation:Continuation.t
      -> descr:string
      -> Flambda.Expr.t * result)
    -> simplify_expr:(
         t
      -> result
      -> Flambda.Expr.t
      -> Flambda.Expr.t * result)
    -> simplify_apply_cont_to_cont:(
         ?don't_record_use:unit
      -> t
      -> result
      -> Continuation.t
      -> arg_tys:Flambda_type.t list
      -> Continuation.t * result)
    -> t

  (** Obtain the first-class module that gives information about the
      compiler backend being used for compilation. *)
  val backend : t -> (module Backend_intf.S)

  (** Prepare an [Flambda_type.with_importer] function for use in the current
      environment. *)
  val with_importer
     : t
    -> 'a Flambda_type.with_importer
    -> 'a

  (** Prepare an [Flambda_type.type_accessor] function for use in the current
      environment. *)
  val type_accessor
     : t
    -> 'a Flambda_type.type_accessor
    -> 'a

  val simplify_toplevel
     : t
    -> (t
      -> result
      -> Flambda.Expr.t
      -> continuation:Continuation.t
      -> descr:string
      -> Flambda.Expr.t * result)

  val simplify_expr
     : t
    -> (t
      -> result
      -> Flambda.Expr.t
      -> Flambda.Expr.t * result)

  val simplify_apply_cont_to_cont
     : t
    -> (?don't_record_use:unit
      -> t
      -> result
      -> Continuation.t
      -> arg_tys:Flambda_type.t list
      -> Continuation.t * result)

  val importer : t -> (module Flambda_type.Importer)

  (** Which simplification round we are currently in. *)
  val round : t -> int

  (** Add the type of a variable---that is to say, some knowledge
      about the value(s) the variable may take on at runtime---to the
      environment. *)
  val add_variable : t -> Variable.t -> Flambda_type.t -> t

  (** Like [add], but for mutable variables. *)
  val add_mutable : t -> Mutable_variable.t -> Flambda_type.t -> t

  (* CR mshinwell: The [Continuation.t] is in the [Continuation.approx.t] *)
  val add_continuation : t -> Continuation.t -> Continuation_approx.t -> t

  val find_continuation : t -> Continuation.t -> Continuation_approx.t

  val mem_continuation : t -> Continuation.t -> bool

  (** Find the approximation of a given variable, raising a fatal error if
      the environment does not know about the variable.  Use [find_opt]
      instead if you need to catch the failure case. *)
  val find_var : t -> Variable.t -> Flambda_type.t

  val find_simple : t -> Simple.t -> Flambda_type.t

  val type_of_name : t -> Name.t -> Flambda_type.t option

  (** Like [find_exn], but for mutable variables. *)
  val find_mutable_exn : t -> Mutable_variable.t -> Flambda_type.t

  type scope = Current | Outer

  val find_with_scope_exn : t -> Variable.t -> scope * Flambda_type.t

  (** Like [find_exn], but intended for use where the "not present in
      environment" case is to be handled by the caller. *)
  val find_opt : t -> Variable.t -> Flambda_type.t option

  (** Like [find_exn], but for a list of variables. *)
  val find_list_exn : t -> Variable.t list -> Flambda_type.t list

  val vars_in_scope : t -> Variable.Set.t

  val does_not_bind : t -> Variable.t list -> bool

  val does_not_freshen : t -> Variable.t list -> bool

  val add_symbol
     : t
    -> Symbol.t
    -> ?definition:Flambda_static.Program_body.definition
    -> Flambda_type.t
    -> t

  (** Mark the given symbol as bound, but with its definition currently unknown,
      to be loaded lazily from a .cmx file. *)
  val import_symbol
     : t
    -> Symbol.t
    -> t

  val redefine_symbol
     : t
    -> Symbol.t
    -> ?definition:Flambda_static.Program_body.definition
    -> Flambda_type.t
    -> t

  val find_symbol : t -> Symbol.t -> Flambda_type.t

  val find_symbol_by_definition
     : t
    -> Flambda_static.Program_body.definition
    -> Symbol.t option

  (* XXX to be turned into equations (including to primitives)
  (** Note that the given [bound_to] holds the given [projection]. *)
  val add_projection
     : t
    -> projection:Projection.t
    -> bound_to:Variable.t
    -> t

  (** Determine if the environment knows about a variable that is bound
      to the given [projection]. *)
  val find_projection
     : t
    -> projection:Projection.t
    -> Variable.t option
  *)

  (** Whether the environment has an approximation for the given variable. *)
  val mem : t -> Variable.t -> bool

  (** Return the freshening that should be applied to variables when
      rewriting code (in [Simplify], etc.) using the given
      environment. *)
  val freshening : t -> Freshening.t

  (** Set the freshening that should be used as per [freshening], above. *)
  val set_freshening : t -> Freshening.t -> t

  (** Causes every bound variable in code rewritten during inlining and
      simplification, using the given environment, to be freshened.  This is
      used when descending into subexpressions substituted into existing
      expressions. *)
  val activate_freshening : t -> t

  (** Erase all variable approximation information and freshening information
      from the given environment.  However, the freshening activation state
      is preserved.  This function is used when rewriting inside a function
      declaration, to avoid (due to a compiler bug) accidental use of
      variables from outer scopes that are not accessible. *)
  val local : t -> t

  (** Determine whether the inliner is currently inside a function body from
      the given set of closures.  This is used to detect whether a given
      function call refers to a function which exists somewhere on the current
      inlining stack. *)
  val inside_set_of_closures_declaration : Set_of_closures_origin.t -> t -> bool

  (** Not inside a closure declaration.
      Toplevel code is the one evaluated when the compilation unit is
      loaded *)
  val at_toplevel : t -> bool

  val is_inside_branch : t -> bool
  val branch_depth : t -> int
  val inside_branch : t -> t

  val increase_closure_depth : t -> t

  (** Mark that call sites contained within code rewritten using the given
      environment should never be replaced by inlined (or unrolled) versions
      of the callee(s). *)
  val set_never_inline : t -> t

  (** Equivalent to [set_never_inline] but only applies to code inside
      a set of closures. *)
  val set_never_inline_inside_closures : t -> t

  (** Unset the restriction from [set_never_inline_inside_closures] *)
  val unset_never_inline_inside_closures : t -> t

  (** Equivalent to [set_never_inline] but does not apply to code inside
      a set of closures. *)
  val set_never_inline_outside_closures : t -> t

  (** Unset the restriction from [set_never_inline_outside_closures] *)
  val unset_never_inline_outside_closures : t -> t

  (** Return whether [set_never_inline] is currently in effect on the given
      environment. *)
  val never_inline : t -> bool

  val never_inline_continuations : t -> bool
  val never_specialise_continuations : t -> bool
  val never_unbox_continuations : t -> bool

  val disallow_continuation_inlining : t -> t
  val disallow_continuation_specialisation : t -> t

  val inlining_level : t -> int

  (** Mark that this environment is used to rewrite code for inlining. This is
      used by the inlining heuristics to decide whether to continue.
      Unconditionally inlined does not take this into account. *)
  val inlining_level_up : t -> t

  (** Whether we are actively unrolling a given function. *)
  val actively_unrolling : t -> Set_of_closures_origin.t -> int option

  (** Start actively unrolling a given function [n] times. *)
  val start_actively_unrolling : t -> Set_of_closures_origin.t -> int -> t

  (** Unroll a function currently actively being unrolled. *)
  val continue_actively_unrolling : t -> Set_of_closures_origin.t -> t

  (** Whether it is permissible to unroll a call to a recursive function
      in the given environment. *)
  val unrolling_allowed : t -> Set_of_closures_origin.t -> bool

  (** Whether the given environment is currently being used to rewrite the
      body of an unrolled recursive function. *)
  val inside_unrolled_function : t -> Set_of_closures_origin.t -> t

  (** Whether it is permissible to inline a call to a function in the given
      environment. *)
  val inlining_allowed : t -> Closure_origin.t -> bool

  (** Whether the given environment is currently being used to rewrite the
      body of an inlined function. *)
  (* CR mshinwell: comment wrong? *)
  val inside_inlined_function : t -> Closure_origin.t -> t

  (** If collecting inlining statistics, record that the inliner is about to
      descend into [closure_id].  This information enables us to produce a
      stack of closures that form a kind of context around an inlining
      decision point. *)
  val note_entering_closure
     : t
    -> closure_id:Closure_id.t
    -> dbg:Debuginfo.t
    -> t

   (** If collecting inlining statistics, record that the inliner is about to
       descend into a call to [closure_id].  This information enables us to
       produce a stack of closures that form a kind of context around an
       inlining decision point. *)
  val note_entering_call
     : t
    -> closure_id:Closure_id.t
    -> dbg:Debuginfo.t
    -> t

   (** If collecting inlining statistics, record that the inliner is about to
       descend into an inlined function call.  This requires that the inliner
       has already entered the call with [note_entering_call]. *)
  val note_entering_inlined : t -> t

   (** If collecting inlining statistics, record that the inliner is about to
       descend into a specialised function definition.  This requires that the
       inliner has already entered the call with [note_entering_call]. *)
  val note_entering_specialised : t -> closure_ids:Closure_id.Set.t -> t

  (** Update a given environment to record that the inliner is about to
      descend into [closure_id] and pass the resulting environment to [f].
      If [inline_inside] is [false] then the environment passed to [f] will be
      marked as [never_inline] (see above). *)
  val enter_closure
     : t
    -> closure_id:Closure_id.t
    -> inline_inside:bool
    -> dbg:Debuginfo.t
    -> f:(t -> 'a)
    -> 'a

   (** If collecting inlining statistics, record an inlining decision for the
       call at the top of the closure stack stored inside the given
       environment. *)
  val record_decision
     : t
    -> Inlining_stats_types.Decision.t
    -> unit

  (** Print a human-readable version of the given environment. *)
  val print : Format.formatter -> t -> unit

  (** The environment stores the call-site being inlined to produce
      precise location information. This function sets the current
      call-site being inlined.  *)
  val set_inline_debuginfo : t -> dbg:Debuginfo.t -> t

  (** Appends the locations of inlined call-sites to the [~dbg] argument *)
  val add_inlined_debuginfo : t -> dbg:Debuginfo.t -> Debuginfo.t

  val continuations_in_scope : t -> Continuation_approx.t Continuation.Map.t
end

module type Result = sig
  (** The result structure used during simplification.  (See simplify.ml.) *)

  type env

  module Continuation_uses : sig
    module Use : sig
      module Kind : sig
        type t =
          | Not_inlinable_or_specialisable of Flambda_type.t list
            (** Do not attempt to inline or specialise the continuation at this
                use point. *)
          | Inlinable_and_specialisable of
              (Simple.t * Flambda_type.t) list
            (** The continuation may be inlined or specialised at this
                use point. *)
          | Only_specialisable of (Simple.t * Flambda_type.t) list
            (** The continuation may be specialised but not inlined at this use
                point.  (Used for [Apply_cont] which have a [trap_action].) *)

        val is_specialisable
           : t
          -> (Simple.t * Flambda_type.t) list option
      end

      type t = private {
        kind : Kind.t;
        env : env;
      }
    end

    type t

    val create
       : continuation:Continuation.t
      -> backend:(module Backend_intf.S)
      -> t

    val print : Format.formatter -> t -> unit

    val application_points : t -> Use.t list

    val unused : t -> bool
    val linearly_used : t -> bool

    val num_uses : t -> int

    val join_of_arg_tys
       : t
      -> num_params:int
      -> Flambda_type.t list

    val join_of_arg_tys_opt : t -> Flambda_type.t list option
  end

  module Continuation_usage_snapshot : sig
    type t

    val continuations_defined_between_snapshots
       : before:t
      -> after:t
      -> Continuation.Set.t
  end

  type t

  val create : unit -> t

  val union : t -> t -> t

  (** Check that [prepare_for_continuation_uses] has been called on the given
      result structure. *)
  val is_used_continuation : t -> Continuation.t -> bool

  (** Mark that the given continuation has been used and provide
      an approximation for the arguments. *)
  val use_continuation
    : t
    -> env
    -> Continuation.t
    -> Continuation_uses.Use.Kind.t
    -> t

  val snapshot_continuation_uses : t -> Continuation_usage_snapshot.t

  val snapshot_and_forget_continuation_uses
     : t
    -> Continuation_usage_snapshot.t * t

  val roll_back_continuation_uses : t -> Continuation_usage_snapshot.t -> t

  val continuation_unused : t -> Continuation.t -> bool
  val continuation_defined : t -> Continuation.t -> bool

  val continuation_args_types
     : t
    -> Continuation.t
    -> arity:Flambda_arity.t
    -> Flambda_type.t list

  (* CR mshinwell: improve names of these two functions *)
  val defined_continuation_args_types
     : t
    -> Continuation.t
    -> arity:Flambda_arity.t
    -> Flambda_type.t list

  (** Continuation usage information for use after examining the body of
      a [Let_cont] but before [define_continuation] has been called. *)
  val continuation_uses : t -> Continuation_uses.t Continuation.Map.t

  val non_recursive_continuations_used_linearly_in_inlinable_position
     : t
    -> Continuation.Set.t

  (** Mark that we are moving up out of the scope of a continuation-binding
      construct. *)
  val exit_scope_of_let_cont
     : t
    -> env
    -> Continuation.t
    -> t * Continuation_uses.t

  (** Record the post-simplification definition of a continuation. *)
  val define_continuation
     : t
    -> Continuation.t
    -> env
    -> Flambda.recursive
    -> Continuation_uses.t
    -> Continuation_approx.t
    -> t

  (** Update all use environments (both for "used" and "defined" continuations)
      such that if [is_present_in_env] is in such an environment then
      [then_add_to_env] will be added with the given approximation.

      This is used after wrappers have been added during continuation unboxing
      to keep [r] up to date. *)
  val update_all_continuation_use_environments
     : t
    -> if_present_in_env:Continuation.t
    -> then_add_to_env:(Continuation.t * Continuation_approx.t)
    -> t

  (** Update the approximation for a defined continuation. *)
  val update_defined_continuation_approx
     : t
    -> Continuation.t
    -> Continuation_approx.t
    -> t

  (** Continuation definition information for the inliner. *)
  val continuation_definitions_with_uses
     : t
    -> (Continuation_uses.t * Continuation_approx.t * env
      * Flambda.recursive) Continuation.Map.t

  val forget_continuation_definition
     : t
    -> Continuation.t
    -> t

  (** Check that there is no continuation binding construct in scope. *)
  val no_continuations_in_scope : t -> bool

  (** All continuations for which [continuation_uses] has been
      called on the given result structure.  O(n*log(n)). *)
  val used_continuations : t -> Continuation.Set.t

  (** The benefit to be gained by inlining the subexpression whose
      simplification yielded the given result structure. *)
  val benefit : t -> Inlining_cost.Benefit.t

  (** Apply a transformation to the inlining benefit stored within the
      given result structure. *)
  val map_benefit
    : t
    -> (Inlining_cost.Benefit.t -> Inlining_cost.Benefit.t)
    -> t

  (** Add some benefit to the inlining benefit stored within the
      given result structure. *)
  val add_benefit : t -> Inlining_cost.Benefit.t -> t

  (** Set the benefit of inlining the subexpression corresponding to the
      given result structure to zero. *)
  val reset_benefit : t -> t

  val set_inlining_threshold :
    t -> Inlining_cost.Threshold.t option -> t
  val add_inlining_threshold :
    t -> Inlining_cost.Threshold.t -> t
  val sub_inlining_threshold :
    t -> Inlining_cost.Threshold.t -> t
  val inlining_threshold : t -> Inlining_cost.Threshold.t option

  val seen_direct_application : t -> t
  val num_direct_applications : t -> int

  (* XXX this must be in the snapshotted part. *)
  val new_lifted_constant
     : t
    -> Env.t
    -> Flambda_static.Static_part.t
    -> Symbol.t * t
end
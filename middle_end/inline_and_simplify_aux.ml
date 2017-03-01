(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2016 OCamlPro SAS                                    *)
(*   Copyright 2014--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

module Env = struct
  type scope = Current | Outer

  type t = {
    backend : (module Backend_intf.S);
    round : int;
    approx : (scope * Simple_value_approx.t) Variable.Map.t;
    approx_mutable : Simple_value_approx.t Mutable_variable.Map.t;
    approx_sym : Simple_value_approx.t Symbol.Map.t;
    continuations : Continuation_approx.t Continuation.Map.t;
    projections : Variable.t Projection.Map.t;
    current_functions : Set_of_closures_origin.Set.t;
    (* The functions currently being declared: used to avoid inlining
       recursively *)
    inlining_level : int;
    (* Number of times "inline" has been called recursively *)
    inside_branch : int;
    freshening : Freshening.t;
    never_inline : bool;
    never_inline_inside_closures : bool;
    never_inline_outside_closures : bool;
    allow_continuation_inlining : bool;
    unroll_counts : int Set_of_closures_origin.Map.t;
    inlining_counts : int Closure_id.Map.t;
    actively_unrolling : int Set_of_closures_origin.Map.t;
    closure_depth : int;
    inlining_stats_closure_stack : Inlining_stats.Closure_stack.t;
    inlined_debuginfo : Debuginfo.t;
  }

  let create ~never_inline ~allow_continuation_inlining ~backend ~round =
    { backend;
      round;
      approx = Variable.Map.empty;
      approx_mutable = Mutable_variable.Map.empty;
      approx_sym = Symbol.Map.empty;
      continuations = Continuation.Map.empty;
      projections = Projection.Map.empty;
      current_functions = Set_of_closures_origin.Set.empty;
      inlining_level = 0;
      inside_branch = 0;
      freshening = Freshening.empty;
      never_inline;
      never_inline_inside_closures = false;
      never_inline_outside_closures = false;
      allow_continuation_inlining = allow_continuation_inlining;
      unroll_counts = Set_of_closures_origin.Map.empty;
      inlining_counts = Closure_id.Map.empty;
      actively_unrolling = Set_of_closures_origin.Map.empty;
      closure_depth = 0;
      inlining_stats_closure_stack =
        Inlining_stats.Closure_stack.create ();
      inlined_debuginfo = Debuginfo.none;
    }

  let backend t = t.backend
  let round t = t.round

  let local env =
    { env with
      approx = Variable.Map.empty;
      continuations = Continuation.Map.empty;
      projections = Projection.Map.empty;
      freshening = Freshening.empty_preserving_activation_state env.freshening;
      inlined_debuginfo = Debuginfo.none;
    }

  let inlining_level_up env =
    let max_level =
      Clflags.Int_arg_helper.get ~key:(env.round) !Clflags.inline_max_depth
    in
    if (env.inlining_level + 1) > max_level then
      Misc.fatal_error "Inlining level increased above maximum";
    { env with inlining_level = env.inlining_level + 1 }

  let print ppf t =
    Format.fprintf ppf
      "Environment maps: %a@.Projections: %a@.Freshening: %a@.\
        Continuations: %a@."
      Variable.Set.print (Variable.Map.keys t.approx)
      (Projection.Map.print Variable.print) t.projections
      Freshening.print t.freshening
      (Continuation.Map.print Continuation_approx.print) t.continuations

  let mem t var = Variable.Map.mem var t.approx

  let add_internal t var (approx : Simple_value_approx.t) ~scope =
    let approx =
      (* The semantics of this [match] are what preserve the property
         described at the top of simple_value_approx.mli, namely that when a
         [var] is mem on an approximation (amongst many possible [var]s),
         it is the one with the outermost scope. *)
      match approx.var with
      | Some var when mem t var -> approx
      | _ -> Simple_value_approx.augment_with_variable approx var
    in
    { t with approx = Variable.Map.add var (scope, approx) t.approx }

  let add t var approx = add_internal t var approx ~scope:Current
  let add_outer_scope t var approx = add_internal t var approx ~scope:Outer

  let add_mutable t mut_var approx =
    { t with approx_mutable =
        Mutable_variable.Map.add mut_var approx t.approx_mutable;
    }

  let really_import_approx t =
    let module Backend = (val (t.backend) : Backend_intf.S) in
    Backend.really_import_approx

  let really_import_approx_with_scope t (scope, approx) =
    scope, really_import_approx t approx

  let find_symbol_exn t symbol =
    really_import_approx t
      (Symbol.Map.find symbol t.approx_sym)

  let find_symbol_opt t symbol =
    try Some (really_import_approx t
                (Symbol.Map.find symbol t.approx_sym))
    with Not_found -> None

  let find_symbol_fatal t symbol =
    match find_symbol_exn t symbol with
    | exception Not_found ->
      Misc.fatal_errorf "Symbol %a is unbound.  Maybe there is a missing \
          [Let_symbol], [Import_symbol] or similar?"
        Symbol.print symbol
    | approx -> approx

  let find_or_load_symbol t symbol =
    match find_symbol_exn t symbol with
    | exception Not_found ->
      if Compilation_unit.equal
          (Compilation_unit.get_current_exn ())
          (Symbol.compilation_unit symbol)
      then
        Misc.fatal_errorf "Symbol %a from the current compilation unit is \
            unbound.  Maybe there is a missing [Let_symbol] or similar?"
          Symbol.print symbol;
      let module Backend = (val (t.backend) : Backend_intf.S) in
      Backend.import_symbol symbol
    | approx -> approx

  let add_projection t ~projection ~bound_to =
    { t with
      projections =
        Projection.Map.add projection bound_to t.projections;
    }

  let find_projection t ~projection =
    match Projection.Map.find projection t.projections with
    | exception Not_found -> None
    | var -> Some var

  let add_continuation t cont approx =
    { t with
      continuations = Continuation.Map.add cont approx t.continuations;
    }

  let find_continuation t cont =
    match Continuation.Map.find cont t.continuations with
    | exception Not_found ->
      Misc.fatal_errorf "Unbound continuation %a.\n@ \n%a\n%!"
        Continuation.print cont
        print t
    | approx -> approx

  let does_not_bind t vars =
    not (List.exists (mem t) vars)

  let does_not_freshen t vars =
    Freshening.does_not_freshen t.freshening vars

  let add_symbol t symbol approx =
    match find_symbol_exn t symbol with
    | exception Not_found ->
      { t with
        approx_sym = Symbol.Map.add symbol approx t.approx_sym;
      }
    | _ ->
      Misc.fatal_errorf "Attempt to redefine symbol %a (to %a) in environment \
          for [Inline_and_simplify]"
        Symbol.print symbol
        Simple_value_approx.print approx

  let redefine_symbol t symbol approx =
    match find_symbol_exn t symbol with
    | exception Not_found ->
      assert false
    | _ ->
      { t with
        approx_sym = Symbol.Map.add symbol approx t.approx_sym;
      }

  let find_with_scope_exn t id =
    try
      really_import_approx_with_scope t
        (Variable.Map.find id t.approx)
    with Not_found ->
      Misc.fatal_errorf "Env.find_with_scope_exn: Unbound variable \
          %a@.%s@. Environment: %a@."
        Variable.print id
        (Printexc.raw_backtrace_to_string (Printexc.get_callstack max_int))
        print t

  let find_exn t id =
    snd (find_with_scope_exn t id)

  let find_mutable_exn t mut_var =
    try Mutable_variable.Map.find mut_var t.approx_mutable
    with Not_found ->
      Misc.fatal_errorf "Env.find_mutable_exn: Unbound variable \
          %a@.%s@. Environment: %a@."
        Mutable_variable.print mut_var
        (Printexc.raw_backtrace_to_string (Printexc.get_callstack max_int))
        print t

  let find_list_exn t vars =
    List.map (fun var -> find_exn t var) vars

  let vars_in_scope t = Variable.Map.keys t.approx

  let find_opt t id =
    try Some (really_import_approx t
                (snd (Variable.Map.find id t.approx)))
    with Not_found -> None

  let activate_freshening t =
    { t with freshening = Freshening.activate t.freshening }

  let enter_set_of_closures_declaration origin t =
    { t with
      current_functions =
        Set_of_closures_origin.Set.add origin t.current_functions; }

  let inside_set_of_closures_declaration origin t =
    Set_of_closures_origin.Set.mem origin t.current_functions

  let at_toplevel t =
    t.closure_depth = 0

  let is_inside_branch env = env.inside_branch > 0

  let branch_depth env = env.inside_branch

  let inside_branch t =
    { t with inside_branch = t.inside_branch + 1 }

  let set_freshening t freshening  =
    { t with freshening; }

  let increase_closure_depth t =
    let approx =
      Variable.Map.map (fun (_scope, approx) -> Outer, approx) t.approx
    in
    { t with
      approx;
      closure_depth = t.closure_depth + 1;
    }

  let set_never_inline t =
    if t.never_inline then t
    else { t with never_inline = true }

  let set_never_inline_inside_closures t =
    if t.never_inline_inside_closures then t
    else { t with never_inline_inside_closures = true }

  let unset_never_inline_inside_closures t =
    if t.never_inline_inside_closures then
      { t with never_inline_inside_closures = false }
    else t

  let set_never_inline_outside_closures t =
    if t.never_inline_outside_closures then t
    else { t with never_inline_outside_closures = true }

  let unset_never_inline_outside_closures t =
    if t.never_inline_outside_closures then
      { t with never_inline_outside_closures = false }
    else t

  let actively_unrolling t origin =
    match Set_of_closures_origin.Map.find origin t.actively_unrolling with
    | count -> Some count
    | exception Not_found -> None

  let start_actively_unrolling t origin i =
    let actively_unrolling =
      Set_of_closures_origin.Map.add origin i t.actively_unrolling
    in
    { t with actively_unrolling }

  let continue_actively_unrolling t origin =
    let unrolling =
      try
        Set_of_closures_origin.Map.find origin t.actively_unrolling
      with Not_found ->
        Misc.fatal_error "Unexpected actively unrolled function";
    in
    let actively_unrolling =
      Set_of_closures_origin.Map.add origin (unrolling - 1) t.actively_unrolling
    in
    { t with actively_unrolling }

  let unrolling_allowed t origin =
    let unroll_count =
      try
        Set_of_closures_origin.Map.find origin t.unroll_counts
      with Not_found ->
        Clflags.Int_arg_helper.get
          ~key:t.round !Clflags.inline_max_unroll
    in
    unroll_count > 0

  let inside_unrolled_function t origin =
    let unroll_count =
      try
        Set_of_closures_origin.Map.find origin t.unroll_counts
      with Not_found ->
        Clflags.Int_arg_helper.get
          ~key:t.round !Clflags.inline_max_unroll
    in
    let unroll_counts =
      Set_of_closures_origin.Map.add
        origin (unroll_count - 1) t.unroll_counts
    in
    { t with unroll_counts }

  let inlining_allowed t id =
    let inlining_count =
      try
        Closure_id.Map.find id t.inlining_counts
      with Not_found ->
        max 1 (Clflags.Int_arg_helper.get
                 ~key:t.round !Clflags.inline_max_unroll)
    in
    inlining_count > 0

  let inside_inlined_function t id =
    let inlining_count =
      try
        Closure_id.Map.find id t.inlining_counts
      with Not_found ->
        max 1 (Clflags.Int_arg_helper.get
                 ~key:t.round !Clflags.inline_max_unroll)
    in
    let inlining_counts =
      Closure_id.Map.add id (inlining_count - 1) t.inlining_counts
    in
    { t with inlining_counts }

  let inlining_level t = t.inlining_level
  let freshening t = t.freshening
  let never_inline t = t.never_inline || t.never_inline_outside_closures

  let disallow_continuation_inlining t =
    { t with allow_continuation_inlining = false; }

  let never_inline_continuations t =
    never_inline t && not t.allow_continuation_inlining

  let note_entering_closure t ~closure_id ~dbg =
    if t.never_inline then t
    else
      { t with
        inlining_stats_closure_stack =
          Inlining_stats.Closure_stack.note_entering_closure
            t.inlining_stats_closure_stack ~closure_id ~dbg;
      }

  let note_entering_call t ~closure_id ~dbg =
    if t.never_inline then t
    else
      { t with
        inlining_stats_closure_stack =
          Inlining_stats.Closure_stack.note_entering_call
            t.inlining_stats_closure_stack ~closure_id ~dbg;
      }

  let note_entering_inlined t =
    if t.never_inline then t
    else
      { t with
        inlining_stats_closure_stack =
          Inlining_stats.Closure_stack.note_entering_inlined
            t.inlining_stats_closure_stack;
      }

  let note_entering_specialised t ~closure_ids =
    if t.never_inline then t
    else
      { t with
        inlining_stats_closure_stack =
          Inlining_stats.Closure_stack.note_entering_specialised
            t.inlining_stats_closure_stack ~closure_ids;
      }

  let enter_closure t ~closure_id ~inline_inside ~dbg ~f =
    let t =
      if inline_inside && not t.never_inline_inside_closures then t
      else set_never_inline t
    in
    let t = unset_never_inline_outside_closures t in
    f (note_entering_closure t ~closure_id ~dbg)

  let record_decision t decision =
    Inlining_stats.record_decision decision
      ~closure_stack:t.inlining_stats_closure_stack

  let set_inline_debuginfo t ~dbg =
    { t with inlined_debuginfo = dbg }

  let add_inlined_debuginfo t ~dbg =
    Debuginfo.concat t.inlined_debuginfo dbg

  let continuations_in_scope t = t.continuations

  let invariant t =
    if !Clflags.flambda_invariant_checks then begin
      (* Make sure that freshening a continuation through the given
         environment doesn't yield a continuation not bound by the
         environment. *)
      let from_freshening =
        Freshening.range_of_continuation_freshening t.freshening
      in
      Continuation.Set.iter (fun cont ->
          match Continuation.Map.find cont t.continuations with
          | exception Not_found ->
            Misc.fatal_errorf "The freshening in this environment maps to \
                continuation %a, but that continuation is unbound:@;%a"
              Continuation.print cont
              print t
          | _ -> ())
        from_freshening
    end
end

let initial_inlining_threshold ~round : Inlining_cost.Threshold.t =
  let unscaled =
    Clflags.Float_arg_helper.get ~key:round !Clflags.inline_threshold
  in
  (* CR-soon pchambart: Add a warning if this is too big
     mshinwell: later *)
  Can_inline_if_no_larger_than
    (int_of_float
      (unscaled *. float_of_int Inlining_cost.scale_inline_threshold_by))

let initial_inlining_toplevel_threshold ~round : Inlining_cost.Threshold.t =
  let ordinary_threshold =
    Clflags.Float_arg_helper.get ~key:round !Clflags.inline_threshold
  in
  let toplevel_threshold =
    Clflags.Int_arg_helper.get ~key:round !Clflags.inline_toplevel_threshold
  in
  let unscaled =
    (int_of_float ordinary_threshold) + toplevel_threshold
  in
  (* CR-soon pchambart: Add a warning if this is too big
     mshinwell: later *)
  Can_inline_if_no_larger_than
    (unscaled * Inlining_cost.scale_inline_threshold_by)

module Continuation_uses = struct
  module A = Simple_value_approx

  module Use = struct
    module Kind = struct
      type t =
        | Not_inlinable_or_specialisable of Simple_value_approx.t list
        | Inlinable_and_specialisable of
            (Variable.t * Simple_value_approx.t) list
        | Only_specialisable of (Variable.t * Simple_value_approx.t) list

      let args t =
        match t with
        | Not_inlinable_or_specialisable _ -> []
        | Inlinable_and_specialisable args_and_approxs
        | Only_specialisable args_and_approxs ->
          List.map (fun (arg, _approx) -> arg) args_and_approxs

      let args_approxs t =
        match t with
        | Not_inlinable_or_specialisable args_approxs -> args_approxs
        | Inlinable_and_specialisable args_and_approxs
        | Only_specialisable args_and_approxs ->
          List.map (fun (_arg, approx) -> approx) args_and_approxs

(*
      let has_useful_approx t =
        List.exists (fun approx -> A.useful approx) (args_approxs t)
*)

      let is_inlinable t =
        match t with
        | Not_inlinable_or_specialisable _ -> false
        | Inlinable_and_specialisable _ -> true
        | Only_specialisable _ -> false

      let is_specialisable t =
        match t with
        | Not_inlinable_or_specialisable _ -> None
        | Inlinable_and_specialisable args_and_approxs
        | Only_specialisable args_and_approxs -> Some args_and_approxs
    end

    type t = {
      kind : Kind.t;
      env : Env.t;
    }
  end

  type t = {
    backend : (module Backend_intf.S);
    continuation : Continuation.t;
    application_points : Use.t list;
  }

  let create ~continuation ~backend =
    { backend;
      continuation;
      application_points = [];
    }

  let add_use t env kind =
    { t with
      application_points = { Use. env; kind; } :: t.application_points;
    }

  let num_application_points t : Num_continuation_uses.t =
    match t.application_points with
    | [] -> Zero
    | [_] -> One
    | _ -> Many

  let unused t =
    match num_application_points t with
    | Zero -> true
    | One | Many -> false

  let linearly_used t =
    match num_application_points t with
    | Zero -> false
    | One -> true
    | Many -> false

  let linearly_used_in_inlinable_position t =
    match t.application_points with
    | [use] when Use.Kind.is_inlinable use.kind -> true
    | _ -> false

  (* CR mshinwell: this should be called "join" *)
  let meet_of_args_approxs_opt t =
    match t.application_points with
    | [] -> None
    | use::uses ->
      Some (List.fold_left (fun args_approxs (use : Use.t) ->
          let args_approxs' = Use.Kind.args_approxs use.kind in
          if List.length args_approxs <> List.length args_approxs' then begin
            Misc.fatal_errorf "meet_of_args_approx_opt %a: approx length %d, \
                use length %d"
              Continuation.print t.continuation
              (List.length args_approxs) (List.length args_approxs')
          end;
          List.map2 (fun approx1 approx2 ->
              let module Backend = (val (t.backend) : Backend_intf.S) in
              A.join approx1 approx2
                ~really_import_approx:Backend.really_import_approx)
            args_approxs args_approxs')
        (Use.Kind.args_approxs use.kind)
        uses)

  let meet_of_args_approxs t ~num_params =
    match meet_of_args_approxs_opt t with
    | None -> Array.to_list (Array.make num_params (A.value_unknown Other))
    | Some join -> join

  let application_points t = t.application_points
(*
  let filter_out_non_useful_uses t =
    (* CR mshinwell: This should check that the approximation is always
       better than the join.  We could do this easily by adding an equality
       function to Simple_value_approx and then using that in conjunction with
       the "join" function *)
    let application_points =
      List.filter (fun (use : Use.t) ->
          Use.Kind.has_useful_approx use.kind)
        t.application_points
    in
    { t with application_points; }
*)

  let map_use_environments t ~f =
    let application_points =
      List.map (fun (use : Use.t) ->
          { use with
            env = f use.env;
          })
        t.application_points
    in
    { t with application_points; }
end

module Continuation_usage_snapshot = struct
  type t = {
    used_continuations : Continuation_uses.t Continuation.Map.t;
    defined_continuations :
      (Continuation_uses.t * Continuation_approx.t * Env.t
          * Asttypes.rec_flag)
        Continuation.Map.t;
  }

  let continuations_defined_between_snapshots ~before ~after =
    Continuation.Set.diff
      (Continuation.Map.keys after.defined_continuations)
      (Continuation.Map.keys before.defined_continuations)
end

module Result = struct
  type t =
    { approx : Simple_value_approx.t;
      (* CR mshinwell: What about combining these next two? *)
      used_continuations : Continuation_uses.t Continuation.Map.t;
      defined_continuations :
        (Continuation_uses.t * Continuation_approx.t * Env.t
            * Asttypes.rec_flag)
          Continuation.Map.t;
      inlining_threshold : Inlining_cost.Threshold.t option;
      benefit : Inlining_cost.Benefit.t;
      num_direct_applications : int;
    }

  let create () =
    { approx = Simple_value_approx.value_unknown Other;
      used_continuations = Continuation.Map.empty;
      defined_continuations = Continuation.Map.empty;
      inlining_threshold = None;
      benefit = Inlining_cost.Benefit.zero;
      num_direct_applications = 0;
    }

  let approx t = t.approx
  let set_approx t approx = { t with approx }

  let meet_approx t env approx =
    let really_import_approx = Env.really_import_approx env in
    let meet =
      Simple_value_approx.join ~really_import_approx t.approx approx
    in
    set_approx t meet

  let use_continuation t env cont kind =
    let args = Continuation_uses.Use.Kind.args kind in
    if not (List.for_all (fun arg -> Env.mem env arg) args) then begin
      Misc.fatal_errorf "use_continuation %a: argument(s) (%a) not in \
          environment %a"
        Continuation.print cont
        Variable.print_list args
        Env.print env
    end;
(*
let k = 128 in
if Continuation.to_int cont = k then begin
  Format.eprintf "Adding use of continuation k%d, num_args %d:\n%s\n%!"
    k
    (List.length args_approxs)
    (Printexc.raw_backtrace_to_string (Printexc.get_callstack 10))
end;
*)
    let uses =
      match Continuation.Map.find cont t.used_continuations with
      | exception Not_found ->
        Continuation_uses.create ~continuation:cont ~backend:(Env.backend env)
      | uses -> uses
    in
    let uses = Continuation_uses.add_use uses env kind in
    { t with
      used_continuations =
        Continuation.Map.add cont uses t.used_continuations;
    }

  let non_recursive_continuations_used_linearly_in_inlinable_position t =
    let used_linearly =
      Continuation.Map.filter (fun _cont (uses, _approx, _env, recursive) ->
(*
Format.eprintf "NRCUL: continuation %a number of uses %d\n%!"
  Continuation.print _cont
  (List.length uses.Continuation_uses.application_points);
*)
          match (recursive : Asttypes.rec_flag) with
          | Nonrecursive ->
            Continuation_uses.linearly_used_in_inlinable_position uses
          | Recursive -> false)
        t.defined_continuations
    in
    Continuation.Map.keys used_linearly

  let forget_continuation_definition t cont =
    { t with
      defined_continuations =
        Continuation.Map.remove cont t.defined_continuations;
    }

  let is_used_continuation t i =
    Continuation.Map.mem i t.used_continuations

  let used_continuations t =
    Continuation.Map.keys t.used_continuations

  let continuation_uses t = t.used_continuations

  let no_continuations_in_scope t =
    Continuation.Map.is_empty t.used_continuations

  let snapshot_continuation_uses t =
    { Continuation_usage_snapshot.
      used_continuations = t.used_continuations;
      defined_continuations = t.defined_continuations;
    }

  let snapshot_and_forget_continuation_uses t =
    let snapshot = snapshot_continuation_uses t in
    let t =
      { t with
        used_continuations = Continuation.Map.empty;
        defined_continuations = Continuation.Map.empty;
      }
    in
    snapshot, t

  let roll_back_continuation_uses t (snapshot : Continuation_usage_snapshot.t) =
    { t with
      used_continuations = snapshot.used_continuations;
      defined_continuations = snapshot.defined_continuations;
    }

  let continuation_unused t cont =
    not (Continuation.Map.mem cont t.used_continuations)

  let continuation_args_approxs t i ~num_params =
    match Continuation.Map.find i t.used_continuations with
    | exception Not_found ->
      let approxs =
        Array.make num_params (Simple_value_approx.value_unknown Other)
      in
      Array.to_list approxs
    | uses ->
      Continuation_uses.meet_of_args_approxs uses ~num_params

  let exit_scope_catch ?update_use_env t env i =
    match Continuation.Map.find i t.used_continuations with
    | exception Not_found ->
      let uses =
        Continuation_uses.create ~continuation:i ~backend:(Env.backend env)
      in
      t, uses
    | uses ->
      let uses =
        match update_use_env with
        | None -> uses
        | Some f ->
          Continuation_uses.map_use_environments uses ~f
      in
      { t with
        used_continuations = Continuation.Map.remove i t.used_continuations;
      }, uses

  let define_continuation t cont env recursive uses approx =
(*
let k = 14898 in
if Continuation.to_int cont = k then begin
  Format.eprintf "Defining continuation k%d:\n%s%!"
    k
    (Printexc.raw_backtrace_to_string (Printexc.get_callstack 10))
end;
*)
    Env.invariant env;
    { t with
      defined_continuations =
        Continuation.Map.add cont (uses, approx, env, recursive)
          t.defined_continuations;
    }

  let continuation_definitions_with_uses t =
    t.defined_continuations

  let map_benefit t f =
    { t with benefit = f t.benefit }

  let add_benefit t b =
    { t with benefit = Inlining_cost.Benefit.(+) t.benefit b }

  let benefit t = t.benefit

  let reset_benefit t =
    { t with benefit = Inlining_cost.Benefit.zero; }

  let set_inlining_threshold t inlining_threshold =
    { t with inlining_threshold }

  let add_inlining_threshold t j =
    match t.inlining_threshold with
    | None -> t
    | Some i ->
      let inlining_threshold = Some (Inlining_cost.Threshold.add i j) in
      { t with inlining_threshold }

  let sub_inlining_threshold t j =
    match t.inlining_threshold with
    | None -> t
    | Some i ->
      let inlining_threshold = Some (Inlining_cost.Threshold.sub i j) in
      { t with inlining_threshold }

  let inlining_threshold t = t.inlining_threshold

  let seen_direct_application t =
    { t with num_direct_applications = t.num_direct_applications + 1; }

  let num_direct_applications t =
    t.num_direct_applications
end

module A = Simple_value_approx
module E = Env

let prepare_to_simplify_set_of_closures ~env
      ~(set_of_closures : Flambda.set_of_closures)
      ~function_decls ~freshen
      ~(only_for_function_decl : Flambda.function_declaration option) =
  let free_vars =
    Variable.Map.map (fun (external_var : Flambda.free_var) ->
        let var =
          let var =
            Freshening.apply_variable (E.freshening env) external_var.var
          in
          match
            A.simplify_var_to_var_using_env (E.find_exn env var)
              ~is_present_in_env:(fun var -> E.mem env var)
          with
          | None -> var
          | Some var -> var
        in
        let approx = E.find_exn env var in
        (* The projections are freshened below in one step, once we know
           the closure freshening substitution. *)
        let projection = external_var.projection in
        ({ var; projection; } : Flambda.free_var), approx)
      set_of_closures.free_vars
  in
  let specialised_args =
    Variable.Map.filter_map set_of_closures.specialised_args
      ~f:(fun param (spec_to : Flambda.specialised_to) ->
        let keep =
          match only_for_function_decl with
          | None -> true
          | Some function_decl ->
            Variable.Set.mem param (Variable.Set.of_list function_decl.params)
        in
        if not keep then None
        else
          match spec_to.var with
          | Some external_var ->
            let var =
              Freshening.apply_variable (E.freshening env) external_var
            in
            let var =
              match
                A.simplify_var_to_var_using_env (E.find_exn env var)
                  ~is_present_in_env:(fun var -> E.mem env var)
              with
              | None -> var
              | Some var -> var
            in
            let projection = spec_to.projection in
            Some ({ var = Some var; projection; } : Flambda.specialised_to)
          | None ->
            Misc.fatal_errorf "No equality to variable for specialised arg %a"
              Variable.print param)
  in
  let environment_before_cleaning = env in
  (* [E.local] helps us to catch bugs whereby variables escape their scope. *)
  let env = E.local env in
  let free_vars, function_decls, sb, freshening =
    Freshening.apply_function_decls_and_free_vars (E.freshening env) free_vars
      function_decls ~only_freshen_parameters:(not freshen)
  in
  let env = E.set_freshening env sb in
  let free_vars =
    Freshening.freshen_free_vars_projection_relation' free_vars
      ~freshening:(E.freshening env)
      ~closure_freshening:(Some freshening)
  in
  let specialised_args =
    let specialised_args =
      Variable.Map.map_keys (Freshening.apply_variable (E.freshening env))
        specialised_args
    in
    Freshening.freshen_specialised_args_projection_relation specialised_args
      ~freshening:(E.freshening env)
      ~closure_freshening:(Some freshening)
  in
  let parameter_approximations =
    (* Approximations of parameters that are known to always hold the same
       argument throughout the body of the function. *)
    (* CR mshinwell: This next line might be a duplicate of a line above? *)
    Variable.Map.map_keys (Freshening.apply_variable (E.freshening env))
      (Variable.Map.mapi (fun param (spec_to : Flambda.specialised_to) ->
          match spec_to.var with
          | Some var -> E.find_exn environment_before_cleaning var
          | None ->
            Misc.fatal_errorf "No equality to variable for specialised arg %a"
              Variable.print param)
        specialised_args)
  in
  let direct_call_surrogates =
    Variable.Map.fold (fun existing surrogate surrogates ->
        let existing =
          Freshening.Project_var.apply_closure_id freshening
            (Closure_id.wrap existing)
        in
        let surrogate =
          Freshening.Project_var.apply_closure_id freshening
            (Closure_id.wrap surrogate)
        in
        assert (not (Closure_id.Map.mem existing surrogates));
        Closure_id.Map.add existing surrogate surrogates)
      set_of_closures.direct_call_surrogates
      Closure_id.Map.empty
  in
  let env =
    E.enter_set_of_closures_declaration
      function_decls.set_of_closures_origin env
  in
  (* we use the previous closure for evaluating the functions *)
  let internal_value_set_of_closures =
    let bound_vars =
      Variable.Map.fold (fun id (_, desc) map ->
          Var_within_closure.Map.add (Var_within_closure.wrap id) desc map)
        free_vars Var_within_closure.Map.empty
    in
    A.create_value_set_of_closures ~function_decls ~bound_vars
      ~invariant_params:(lazy Variable.Map.empty) ~specialised_args
      ~freshening ~direct_call_surrogates
  in
  (* Populate the environment with the approximation of each closure.
     This part of the environment is shared between all of the closures in
     the set of closures. *)
  let set_of_closures_env =
    Variable.Map.fold (fun closure _ env ->
        let approx =
          A.value_closure ~closure_var:closure
            (Closure_id.Map.singleton (Closure_id.wrap closure)
               internal_value_set_of_closures)
        in
        E.add env closure approx
      )
      function_decls.funs env
  in
  free_vars, specialised_args, function_decls, parameter_approximations,
    internal_value_set_of_closures, set_of_closures_env

(* This adds only the minimal set of approximations to the closures.
   It is not strictly necessary to have this restriction, but it helps
   to catch potential substitution bugs. *)
let populate_closure_approximations
      ~(function_decl : Flambda.function_declaration)
      ~(free_vars : (_ * A.t) Variable.Map.t)
      ~(parameter_approximations : A.t Variable.Map.t)
      ~set_of_closures_env =
  (* Add approximations of free variables *)
  let env =
    Variable.Map.fold (fun id (_, desc) env ->
        E.add_outer_scope env id desc)
      free_vars set_of_closures_env
  in
  (* Add known approximations of function parameters *)
  let env =
    List.fold_left (fun env id ->
        let approx =
          try Variable.Map.find id parameter_approximations
          with Not_found -> (A.value_unknown Other)
        in
        E.add env id approx)
      env function_decl.params
  in
  env

let prepare_to_simplify_closure ~(function_decl : Flambda.function_declaration)
      ~free_vars ~specialised_args ~parameter_approximations
      ~set_of_closures_env =
  let closure_env =
    populate_closure_approximations ~function_decl ~free_vars
      ~parameter_approximations ~set_of_closures_env
  in
  (* Add definitions of known projections to the environment. *)
  let add_projections ~closure_env ~which_variables ~get_projection =
    Variable.Map.fold (fun inner_var param env ->
        match get_projection param with
        | None -> env
        | Some projection ->
          let from = Projection.projecting_from projection in
          if Variable.Set.mem from function_decl.free_variables then
            E.add_projection env ~projection ~bound_to:inner_var
          else
            env)
      which_variables
      closure_env
  in
  let closure_env =
    add_projections ~closure_env ~which_variables:specialised_args
      ~get_projection:(fun (spec_arg : Flambda.specialised_to) ->
        spec_arg.projection)
  in
  add_projections ~closure_env ~which_variables:free_vars
    ~get_projection:(fun ((fv : Flambda.free_var), _) -> fv.projection)

(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2016 OCamlPro SAS                                          *)
(*   Copyright 2016 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

module A = Simple_value_approx
module E = Inline_and_simplify_aux.Env
module R = Inline_and_simplify_aux.Result

type specialising_result =
  | Didn't_specialise
  | Specialised of Continuation.t * Flambda.let_cont_handlers

(* This function constructs a suitable environment for simplification of a
   continuation's body that is eligible for specialisation.  The freshening
   of the body is performed during the simplification.

   If the continuation is defined simultaneously with others, all of the
   bodies will be simplified; specialised argument information may also be
   introduced for continuations in the same group using the invariant
   parameters flow information.  This saves multiple rounds of simplification
   being required to propagate around mutually-recursive continuations.
*)
let try_specialising ~cont ~(old_handlers : Flambda.continuation_handlers)
      ~(newly_specialised_args : Flambda.specialised_args)
      ~invariant_params_flow ~env ~recursive ~simplify_let_cont_handlers
      ~definitions_with_uses : specialising_result =
  let freshening =
    Continuation.Map.fold (fun cont _handler freshening ->
        let _new_cont, freshening =
          Freshening.add_static_exception freshening cont
        in
        freshening)
      old_handlers
      (Freshening.activate (E.freshening env))
  in
  let env =
    E.disallow_continuation_inlining (
      E.set_never_inline (E.set_freshening env freshening))
  in
  let env =
    Continuation.Map.fold (fun cont (handler : Flambda.continuation_handler)
              env ->
        let cont = Freshening.apply_static_exception (E.freshening env) cont in
        let approx =
          Continuation_approx.create_unknown ~name:cont
            ~num_params:(List.length handler.params)
        in
        E.add_continuation env cont approx)
      old_handlers
      env
  in
  let entry_point_cont = cont in
  let entry_point_new_cont =
    Freshening.apply_static_exception freshening cont
  in
  let new_handlers =
    Continuation.Map.fold (fun cont (old_handler : Flambda.continuation_handler)
            new_handlers ->
        let wrong_spec_args =
          Variable.Set.inter (Variable.Map.keys old_handler.specialised_args)
            (Variable.Map.keys newly_specialised_args)
        in
        if not (Variable.Set.is_empty wrong_spec_args) then begin
           Misc.fatal_errorf "These parameters of continuation %a have already \
              been specialised: %a"
            Continuation.print cont
            Variable.Set.print wrong_spec_args
        end;
        (* Compute the newly-specialised args.  These are either:
           (a) those arising from the "entry point" (i.e. [Apply_cont] of
               [entry_point_cont]); or
           (b) those arising from invariant parameters flow from the entry
               point's continuation handler. *)
        let newly_specialised_args =
          if Continuation.equal cont entry_point_cont then
            newly_specialised_args
          else
            Variable.Map.fold (fun param (spec_to : Flambda.specialised_to)
                    newly_specialised_args ->
                match Variable.Map.find param invariant_params_flow with
                | exception Not_found -> newly_specialised_args
                | flows_to ->
                  let module CV =
                    Invariant_params.Continuations.Continuation_and_variable
                  in
                  CV.Set.fold (fun (cont', param')
                          newly_specialised_args ->
                      if not (Continuation.equal cont cont') then
                        newly_specialised_args
                      else
                        Variable.Map.add param' spec_to
                          newly_specialised_args)
                    flows_to
                    newly_specialised_args)
              newly_specialised_args
              Variable.Map.empty
        in
        let specialised_args =
          Variable.Map.disjoint_union old_handler.specialised_args
            newly_specialised_args
        in
        let new_handler =
          { old_handler with
            specialised_args;
          }
        in
        let cont = Freshening.apply_static_exception freshening cont in
        Continuation.Map.add cont new_handler new_handlers)
      old_handlers
      Continuation.Map.empty
  in
  let r =
    (* Add usage information for the parameters of the continuations.  The
       parameters are partitioned into two:
       1. the specialised arguments (either pre-existing or
          newly-specialised) with corresponding "specialised-to" variables
          (as opposed to specialised arguments just holding projection
          information), whose approximations are given by those in the
          environment of the variables being specialised to.  When
          newly-specialised arguments are added this should produce an
          increase in precision of the approximations over and above that
          used when the handler was previously simplified;
       2. other arguments, whose approximations will be the same as they were
          when the handler was previously simplified.  (Such approximations
          are the join of the approximations at all use points.)
       Apart from this information, the [r] used for simplification is
       empty. *)
    Continuation.Map.fold (fun cont
            (handler : Flambda.continuation_handler) r ->
        let join_approxs =
          match Continuation.Map.find cont definitions_with_uses with
          | exception Not_found ->
            Misc.fatal_errorf "Continuation %a does not occur in the \
                definitions-with-uses set (only maps %a)"
              Continuation.print cont
              Continuation.Set.print
              (Continuation.Map.keys definitions_with_uses)
          | (uses, _approx, _env, _recursive) ->
            Inline_and_simplify_aux.Continuation_uses.meet_of_args_approxs
              uses ~num_params:(List.length handler.params)
        in
        let freshened_cont =
          Freshening.apply_static_exception freshening cont
        in
        let specialised_args =
          match Continuation.Map.find freshened_cont new_handlers with
          | exception Not_found -> assert false  (* see above *)
          | handler -> handler.specialised_args
        in
        let args_approxs =
          List.map2 (fun param join_approx ->
              let param = Parameter.var param in
              match Variable.Map.find param specialised_args with
              | exception Not_found -> join_approx
              | spec_to ->
                match spec_to.var with
                | None -> join_approx
                | Some spec_to ->
                  begin match E.find_opt env spec_to with
                  | None ->
                    Misc.fatal_errorf "Variable %a of %a specialised to %a \
                        but %a is not in the environment:@ \n%a"
                      Variable.print param
                      Continuation.print cont
                      Variable.print spec_to
                      Variable.print spec_to
                      E.print env
                  | Some approx -> approx
                  end)
            handler.params
            join_approxs
        in
(*
Format.eprintf "try_specialising: adding use of %a with args approxs %a\n%!"
  Continuation.print cont
  (Format.pp_print_list A.print) args_approxs;
*)
        R.use_continuation r env freshened_cont
          (Not_inlinable_or_specialisable args_approxs))
      old_handlers
      (R.create ())
  in
  let new_handlers, r =
    simplify_let_cont_handlers ~env ~r ~handlers:new_handlers
      ~args_approxs:None ~recursive ~freshening:(E.freshening env)
      ~update_use_env:(fun env -> env)
  in
  match new_handlers with
  | None ->
(*
Format.eprintf "try_specialising: no handlers!\n%!";
*)
    Didn't_specialise
  | Some new_handlers ->
(*
Format.eprintf "try_specialising: new handlers:\n@ %a\n%!"
  Flambda.print_let_cont_handlers new_handlers;
*)
    let module W = Inlining_cost.Whether_sufficient_benefit in
    let wsb =
      let originals =
        List.map (fun (handler : Flambda.continuation_handler) ->
            handler.handler)
          (Continuation.Map.data old_handlers)
      in
      let new_handlers =
        match (new_handlers : Flambda.let_cont_handlers) with
        | Nonrecursive { handler; _ } -> [handler.handler]
        | Recursive handlers ->
          List.map (fun (handler : Flambda.continuation_handler) ->
              handler.handler)
            (Continuation.Map.data handlers)
        | Alias _ ->
          Misc.fatal_error "simplify_let_cont_handlers should not return Alias"
      in
      (* CR mshinwell: Probably some stuff about jump benefits should be
        added... *)
      W.create_list ~originals
        ~toplevel:(E.at_toplevel env)
        ~branch_depth:(E.branch_depth env)
        new_handlers
        ~benefit:(R.benefit r)
        ~lifting:false
        ~round:(E.round env)
    in
(*
Format.eprintf "Evaluating %a\n%!" (W.print_description ~subfunctions:false) wsb;
*)
    if W.evaluate wsb then Specialised (entry_point_new_cont, new_handlers)
    else Didn't_specialise

let find_specialisations r ~simplify_let_cont_handlers ~backend =
(*
      ~defined_continuations =
*)
  let module N = Num_continuation_uses in
  let module U = Inline_and_simplify_aux.Continuation_uses in
  (* The first step constructs a map:
          (continuation * (specialised_params -> arg))
       -> set of (continuation * args) * environment * ...
     which groups together uses of the continuation where some subset of
     its invariant parameters have the same arguments across those uses.  The
     range of the map enables identification of the corresponding [Apply_cont]
     nodes which will need to be repointed if the continuation is specialised
     for those uses. *)
  let definitions_with_uses = R.continuation_definitions_with_uses r in
  let specialisations =
    (* CR mshinwell: [recursive] appears to be redundant with
       [approx.recursive] *)
    Continuation.Map.fold (fun cont (uses, approx, _env, recursive)
          specialisations ->
        match Continuation_approx.handlers approx with
        | None ->
          (* Applications of continuations inside their own handlers will
             hit this case.  This is equivalent to the "self call" check
             in [Inlining_decision]. *)
          specialisations
        | Some (Nonrecursive { is_exn_handler = true; _ }) ->
          specialisations
        | Some handlers ->
          let handlers, invariant_params, invariant_params_flow =
            match handlers with
            | Nonrecursive handler ->
              let handlers =
                Continuation.Map.add cont handler Continuation.Map.empty
              in
              (* Non-recursive continuation: all parameters are invariant. *)
              let invariant_params =
                List.fold_left (fun invariant_params param ->
                    let param = Parameter.var param in
                    let param_set = Variable.Set.singleton param in
                    Variable.Map.add param param_set invariant_params)
                  Variable.Map.empty
                  handler.params
              in
              let invariant_params_flow = Variable.Map.empty in
              handlers, invariant_params, invariant_params_flow
            | Recursive handlers ->
              let invariant_params =
                Invariant_params.Continuations.invariant_params_in_recursion
                  handlers ~backend
              in
              let invariant_params_flow =
                Invariant_params.Continuations.invariant_param_sources
                  handlers ~backend
              in
              handlers, invariant_params, invariant_params_flow
          in
          (* We don't currently share specialised continuations in the same
             set of recursive handlers between entry points to that set.
             So for example if there is a [Let_cont] binding k1 and k2
             which are recursive and we see [Apply_cont]s that can be
             specialised---one for k1 and one for k2---then they will end up
             each producing a specialised copy of the entire {k1, k2} set. *)
          let handler =
            match Continuation.Map.find cont handlers with
            | handler -> handler
            | exception Not_found ->
              Misc.fatal_errorf "Continuation %a not found in handler map \
                  inside the approximation"
                Continuation.print cont
          in
          List.fold_left (fun specialisations (use : U.Use.t) ->
              match U.Use.Kind.is_specialisable use.kind with
              | None -> specialisations
              | Some args_and_approxs ->
                assert (List.length handler.params
                  = List.length args_and_approxs);
                let params_with_args =
                  Variable.Map.of_list (
                    let params = Parameter.List.vars handler.params in
                    List.combine params args_and_approxs)
                in
                let params_with_specialised_args =
                  Variable.Map.filter (fun param (_arg, arg_approx) ->
(*
Format.eprintf "Considering use of param %a as arg %a, approx %a: \
    Invariant? %b New spec arg? %b Useful approx? %b\n%!"
  Variable.print param
  Variable.print _arg
  Simple_value_approx.print arg_approx
  (Variable.Map.mem param invariant_params)
  (not (Variable.Map.mem param handler.specialised_args))
  (A.useful arg_approx);
*)
                      (not handler.stub)
                        && Variable.Map.mem param invariant_params
                        && not (Variable.Map.mem param
                          handler.specialised_args)
                        && A.useful arg_approx)
                    params_with_args
                in
                if Variable.Map.cardinal params_with_specialised_args < 1 then
                  specialisations
                else
                  let params_with_specialised_args =
                    Variable.Map.map (fun (arg, _) : Flambda.specialised_to ->
                        { var = Some arg;
                          projection = None;
                        })
                      params_with_specialised_args
                  in
                  let key : Continuation_with_specialised_args.t =
                    cont, params_with_specialised_args
                  in
                  let uses, env =
                    match
                      Continuation_with_specialised_args.Map.find key
                        specialisations
                    with
                    | exception Not_found ->
                      Continuation.With_args.Set.empty, use.env
                    | uses, env, _, _, _ -> uses, env
                  in
                  (* We arbitrarily pick the first of the use environments as
                     the environment in which we will try specialising the
                     continuation.  This is correct because the variables to
                     which we are specialising parameters must all occur (and
                     thus have equal approximations) in the environment at
                     every one of the use points we are specialising. *)
                  Variable.Map.iter (fun param
                          (spec_to : Flambda.specialised_to) ->
                      match spec_to.var with
                      | None -> assert false  (* see above *)
                      | Some spec_to ->
                        if not (E.mem use.env spec_to) then begin
                          Misc.fatal_errorf "Newly-specialised parameter %a \
                              of %a (being specialised to %a) is not in this \
                              use environment:@ \n%a"
                            Variable.print param
                            Continuation.print cont
                            Variable.print spec_to
                            E.print use.env
                        end)
                    params_with_specialised_args;
                  let use_args =
                    List.map (fun (arg, _approx) -> arg) args_and_approxs
                  in
                  let uses =
                    Continuation.With_args.Set.add (cont, use_args) uses
                  in
                  Continuation_with_specialised_args.Map.add key
                    (uses, env, invariant_params_flow, handlers, recursive)
                    specialisations)
            specialisations
            (U.application_points uses))
      definitions_with_uses
      Continuation_with_specialised_args.Map.empty
  in
(*
Format.eprintf "Specialisation first stage result:\n%a\n%!"
  (Continuation_with_specialised_args.Map.print
    Continuation.With_args.Set.print) (* type error *)
  specialisations;
*)
  (* The second step takes the map from above and makes a decision for
     each proposed specialisation, returning two maps:
       continuation "k" -> specialisations of "k"
       (continuation * args) -> new "entry" continuation
     The first map is then used to add new [Let_cont] definitions and the
     second is used to rewrite [Apply_cont] to specialised continuations. *)
  Continuation_with_specialised_args.Map.fold (fun
          (cont, newly_specialised_args)
          (cont_application_points, env, invariant_params_flow, old_handlers,
            (recursive : Asttypes.rec_flag))
          ((new_conts, apply_cont_rewrites) as acc) ->
      let is_recursive =
        match recursive with
        | Nonrecursive -> false
        | Recursive -> true
      in
      (* Non-recursive continuations that only have a single (inlinable)
         use point should have been inlined out by [Continuation_inlining].
         (There would be no point in specialising such a continuation here
         in any case, since it's already been simplified under the most
         precise approximations available for its parameters. *)
      if ((not is_recursive)
        && Continuation.With_args.Set.cardinal cont_application_points < 2)
      then begin
        acc
      end else begin
        let () =
          Format.eprintf "Trying to specialise %a (new spec args %a)\n%!"
            Continuation.print cont
            Flambda.print_specialised_args newly_specialised_args
        in
        (* CR mshinwell: We should stop this trying to specialise
           already-specialised arguments.  (It isn't clear whether there is
           such a check for functions.)  This might be easy to do in
           [try_specialising] given a suitable ordering on approximations. *)
Format.eprintf "Trying to specialise %a.  All handlers in group %a\n%!"
  Continuation.print cont
  Continuation.Set.print (Continuation.Map.keys old_handlers);
        match
          try_specialising ~cont ~old_handlers
            ~newly_specialised_args ~invariant_params_flow ~env ~recursive
            ~simplify_let_cont_handlers ~definitions_with_uses
        with
        | Didn't_specialise -> acc
        | Specialised (entry_point_new_cont, new_handlers) ->
          let existing_conts =
            match Continuation.Map.find cont new_conts with
            | exception Not_found -> []
            | existing_conts -> existing_conts
          in
          let new_conts =
            Continuation.Map.add cont (new_handlers :: existing_conts)
              new_conts
          in
          let apply_cont_rewrites =
            Continuation.With_args.Set.fold (fun ((cont', _args) as key)
                    apply_cont_rewrites ->
                assert (Continuation.equal cont cont');
                assert (not (Continuation.With_args.Map.mem key
                  apply_cont_rewrites));
                Continuation.With_args.Map.add key entry_point_new_cont
                  apply_cont_rewrites)
              cont_application_points
              apply_cont_rewrites
          in
          new_conts, apply_cont_rewrites
      end)
    specialisations
    (Continuation.Map.empty, Continuation.With_args.Map.empty)

let insert_specialisations (expr : Flambda.expr) ~vars_in_scope ~new_conts
        ~apply_cont_rewrites =
  let module Placement = Place_continuations.Placement in
  let placed =
    Place_continuations.find_insertion_points expr ~vars_in_scope ~new_conts
  in
  let place ~placement ~around =
    match Placement.Map.find placement placed with
    | exception Not_found -> None
    | handlers_list ->
      let expr =
        List.fold_left (fun body handlers ->
            Flambda.Let_cont {
              body;
              handlers;
            })
          around
          handlers_list
      in
      Some expr
  in
  Flambda_iterators.map_toplevel_expr (fun (expr : Flambda.t) : Flambda.t ->
      match expr with
      | Let { var; defining_expr; body } ->
        let placement : Placement.t = After_let var in
        begin match place ~placement ~around:body with
        | None -> expr
        | Some body -> Flambda.create_let var defining_expr body
        end
      | Let_cont { body; handlers = Nonrecursive { name; handler; }; } ->
        let done_something = ref false in
        let placement : Placement.t = Just_inside_continuation name in
        let handler_body =
          match place ~placement ~around:handler.handler with
          | None -> handler.handler
          | Some handler_body ->
            done_something := true;
            handler_body
        in
        let body =
          let placement : Placement.t =
            After_let_cont (Continuation.Set.singleton name)
          in
          match place ~placement ~around:body with
          | None -> body
          | Some body ->
            done_something := true;
            body
        in
        if not !done_something then expr
        else
          Let_cont {
            body;
            handlers = Nonrecursive { name; handler = {
              handler with handler = handler_body; };
            };
          }
      | Let_cont { body; handlers = Recursive handlers; } ->
        let done_something = ref false in
        let handlers =
          Continuation.Map.mapi (fun name
                  (handler : Flambda.continuation_handler) ->
              let placement : Placement.t = Just_inside_continuation name in
              begin match place ~placement ~around:handler.handler with
              | None -> handler
              | Some handler_body ->
                done_something := true;
                { handler with handler = handler_body; }
              end)
            handlers
        in
        let body =
          let placement : Placement.t =
            After_let_cont (Continuation.Map.keys handlers)
          in
          match place ~placement ~around:body with
          | None -> body
          | Some body ->
            done_something := true;
            body
        in
        if not !done_something then expr
        else Let_cont { body; handlers = Recursive handlers; }
      | Apply_cont (cont, trap_action, args) ->
        let key = cont, args in
        begin match
          Continuation.With_args.Map.find key apply_cont_rewrites
        with
        | exception Not_found -> expr
        | new_cont ->
          (* As per the comment above on [try_specialising], we don't need
             to touch [r] here, since it has already been updated to reflect
             the fact that all [Apply_cont (cont, _, args)] are going to be
             rewritten to point at [new_cont] instead. *)
          Apply_cont (new_cont, trap_action, args)
        end
      | Let_cont { handlers = Alias _; _ }
      | Apply _ | Let_mutable _ | Switch _ | Proved_unreachable -> expr)
    expr

let for_toplevel_expression expr ~vars_in_scope r ~simplify_let_cont_handlers
      ~backend =
(*
Format.eprintf "Input (with {%a} in scope) to Continuation_specialisation:\n@;%a\n"
  Variable.Set.print vars_in_scope
  Flambda.print expr;
*)
  let new_conts, apply_cont_rewrites =
    find_specialisations r ~simplify_let_cont_handlers ~backend
  in
  if Continuation.Map.is_empty new_conts then begin
(*
Format.eprintf "No specialising to do.\n%!";
*)
    expr
  end else begin
let output =
  insert_specialisations expr ~vars_in_scope ~new_conts ~apply_cont_rewrites
in
(*
Format.eprintf "Output of Continuation_specialisation:\n@;%a\n"
  Flambda.print output;
*)
output
  end
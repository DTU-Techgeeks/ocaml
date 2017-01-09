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

module W = Flambda.With_free_variables
(*
let print_continuation_stack ppf stack =
  match stack with
  | [] -> Format.fprintf ppf "<empty stack>"
  | _ ->
    Format.fprintf ppf "%a"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf ";")
        (fun ppf (cont, _) -> Continuation.print ppf cont))
      stack
*)

let rec join_continuation_stacks stack1 stack2 =
  match stack1, stack2 with
  | [], [] | _, [] | [], _ -> []
  | (cont1, rec1)::stack1, (cont2, _rec2)::stack2 ->
    if Continuation.equal cont1 cont2 then
      match (rec1 : Asttypes.rec_flag) with
      | Nonrecursive ->
        (cont1, rec1) :: join_continuation_stacks stack1 stack2
      | Recursive -> []  (* Don't sink lets into recursive continuations. *)
    else []

module State : sig
  type t

  val create : unit -> t

  val should_sink_let : t -> Variable.t -> bool

  val sunken_lets_for_handler
     : t
    -> Continuation.t
    -> (Variable.t * Flambda.named W.t) list

  val add_candidates_to_sink
     : t
    -> sink_into:(Continuation.t * Asttypes.rec_flag) list
    -> candidates_to_sink:Variable.Set.t
    -> t

  val add_candidates_to_sink_from_handler_state
     : t
    -> current_continuation:(Continuation.t * Asttypes.rec_flag)
    -> handler_state:t
    -> except:Variable.Set.t
    -> t

  val is_candidate_to_sink
     : t
    -> Variable.t
    -> (Continuation.t * Asttypes.rec_flag) list option

  val remove_candidate_to_sink
     : t
    -> Variable.t
    -> (Continuation.t * Asttypes.rec_flag) list option * t

  val sink_let
     : t
    -> Variable.t
    -> sink_into:Continuation.t
    -> defining_expr:Flambda.named W.t
    -> t

  val add_to_sink_from_state : t -> from:t -> t
end = struct
  type t = {
    to_sink :
      (Variable.t * Flambda.named W.t) list Continuation.Map.t;
    variables_to_sink : Variable.Set.t;
    candidates_to_sink :
      (Continuation.t * Asttypes.rec_flag) list Variable.Map.t;
  }

  let create () =
    { to_sink = Continuation.Map.empty;
      variables_to_sink = Variable.Set.empty;
      candidates_to_sink = Variable.Map.empty;
    }

  let should_sink_let t var =
    Variable.Set.mem var t.variables_to_sink

  let sunken_lets_for_handler t cont =
    match Continuation.Map.find cont t.to_sink with
    | exception Not_found -> []
    | to_sink -> to_sink

  let add_candidates_to_sink t ~sink_into ~candidates_to_sink =
    let candidates_to_sink =
      Variable.Set.fold (fun candidate candidates_to_sink ->
          Variable.Map.add candidate sink_into
            candidates_to_sink)
        candidates_to_sink
        t.candidates_to_sink
    in
    { t with
      candidates_to_sink;
    }

  let add_candidates_to_sink_from_handler_state t ~current_continuation
        ~handler_state ~except =
    let candidates_to_sink =
      Variable.Map.filter_map handler_state.candidates_to_sink
        ~f:(fun var sink_to ->
          if Variable.Set.mem var except then
            None
          else begin
(*
Format.eprintf "Variable %a coming out of handler, stack is now %a\n%!"
Variable.print var
  print_continuation_stack (current_continuation :: sink_to);
*)
            Some (current_continuation :: sink_to)
          end)
    in
    let candidates_to_sink =
      Variable.Map.union (fun _var sink_to1 sink_to2 ->
          Some (join_continuation_stacks sink_to1 sink_to2))
        candidates_to_sink
        t.candidates_to_sink
    in
    { t with
      candidates_to_sink;
    }

  let is_candidate_to_sink t var =
    match Variable.Map.find var t.candidates_to_sink with
    | exception Not_found -> None
    | sink_to -> Some sink_to

  let remove_candidate_to_sink t var =
    let sink_to =
      match Variable.Map.find var t.candidates_to_sink with
      | exception Not_found -> None
      | sink_to -> Some sink_to
    in
    let candidates_to_sink =
      Variable.Map.remove var t.candidates_to_sink
    in
    let t =
      { t with
        candidates_to_sink;
      }
    in
    sink_to, t

  let sink_let t var ~sink_into ~defining_expr =
    let to_sink =
      let to_sink =
        match Continuation.Map.find sink_into t.to_sink with
        | exception Not_found -> []
        | to_sink -> to_sink
      in
      Continuation.Map.add sink_into ((var, defining_expr) :: to_sink)
        t.to_sink
    in
    let variables_to_sink = Variable.Set.add var t.variables_to_sink in
    { t with
      to_sink;
      variables_to_sink;
    }

  let add_to_sink_from_state t ~from =
    let to_sink = Continuation.Map.disjoint_union t.to_sink from.to_sink in
    let variables_to_sink =
      Variable.Set.union t.variables_to_sink from.variables_to_sink
    in
    { t with
      to_sink;
      variables_to_sink;
    }
end

let rec sink_expr (expr : Flambda.expr) ~state : Flambda.expr * State.t =
  match expr with
  | Let ({ var; defining_expr; body; } as let_expr) ->
    let body, state = sink_expr body ~state in
    let defining_expr, state =
      match defining_expr with
      | Set_of_closures set_of_closures ->
        let set_of_closures = sink_set_of_closures set_of_closures in
        let defining_expr : Flambda.named = Set_of_closures set_of_closures in
        W.of_named defining_expr, state
      | _ -> W.of_defining_expr_of_let let_expr, state
    in
    let sink_into, state = State.remove_candidate_to_sink state var in
    let state =
      match sink_into with
      | Some sink_into
        when Effect_analysis.only_generative_effects_named
          (W.to_named defining_expr) ->
(*
Format.eprintf "binding for %a: sink_into not reversed is %a\n%!"
  Variable.print var
  (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf " ")
    Continuation.print) (List.map fst sink_into);
*)
        begin match List.rev sink_into with
        | [] -> state
        | (sink_into, _recursive)::_  (* ) as s*) ->
(*
Format.eprintf "binding for %a: reversed being sunk to %a\n%!"
  Variable.print var
  (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf " ")
    Continuation.print) (List.map fst s);
*)
          State.sink_let state var ~sink_into ~defining_expr
        end
      | _ ->
(*
Format.eprintf "binding for %a: not to be moved\n%!"
  Variable.print var;
*)
        state
    in
    let add_candidates ~sink_into =
(*
let var' = var in
*)
      Variable.Set.fold (fun var state ->
(*
Format.eprintf "Considering fv %a of defining_expr of %a: "
  Variable.print var Variable.print var';
*)
          let sink_into =
            match State.is_candidate_to_sink state var with
            | None ->
(*
Format.eprintf "not a candidate --> %a\n%!"
  print_continuation_stack sink_into;
*)
              sink_into
            | Some sink_into' ->
(*
let result =
*)
                join_continuation_stacks sink_into sink_into'
(*
in
Format.eprintf "joining: already needed at %a now also needed at %a --> %a\n%!"
  print_continuation_stack sink_into'
  print_continuation_stack sink_into
  print_continuation_stack result;
result
*)
          in
          State.add_candidates_to_sink state
            ~sink_into
            ~candidates_to_sink:(Variable.Set.singleton var))
        (W.free_variables defining_expr)
        state
    in
    let keep_let () =
      W.create_let_reusing_defining_expr var defining_expr body
    in
    let only_generative_effects =
      Effect_analysis.only_generative_effects_named
        (W.to_named defining_expr)
    in
    (* CR mshinwell: Try to improve the structure of the code here and
        above *)
    begin match sink_into with
    | Some sink_into when only_generative_effects ->
      keep_let (), add_candidates ~sink_into
    | Some _sink_into ->
      keep_let (), add_candidates ~sink_into:[]
    | None ->
      if only_generative_effects then begin
(*
Format.eprintf "deleting let %a\n%!" Variable.print var;
*)
        body, state
      end else begin
(*
Format.eprintf "having to keep let %a, might have side effect\n%!"
  Variable.print var;
*)
        keep_let (), add_candidates ~sink_into:[]
      end
    end
  | Let_mutable { var; initial_value; contents_kind; body; }->
    let body, state = sink_expr body ~state in
    let state =
      State.add_candidates_to_sink state
        ~sink_into:[]
        ~candidates_to_sink:(Variable.Set.singleton initial_value)
    in
    Let_mutable { var; initial_value; contents_kind; body; }, state
  | Let_cont { name; body; handler = (Alias _) as handler; } ->
    let body, state = sink_expr body ~state in
    Let_cont { name; body; handler; }, state
  | Let_cont { name; body; handler =
      Handler { params; recursive = Recursive; handler; specialised_args; } } ->
    (* We don't sink anything into a recursive continuation. *)
    (* CR mshinwell: This is actually required for correctness at the moment
       since e.g. mutable block creation is deemed as "no generative effects"
       but cannot unconditionally be moved into loops. *)
    let body = sink body in
    let handler = sink handler in
    let fvs =
      Variable.Set.union
        (Flambda.free_variables_of_specialised_args specialised_args)
        (Variable.Set.union (Flambda.free_variables body)
          (Flambda.free_variables handler))
    in
    let state =
      State.add_candidates_to_sink (State.create ())
        ~sink_into:[]
        ~candidates_to_sink:fvs
    in
    Let_cont { name; body; handler =
        Handler { params; recursive = Recursive; handler;
          specialised_args; } },
      state
  | Let_cont { name; body; handler =
      Handler { params; recursive; handler; specialised_args; } } ->
    let params_set = Variable.Set.of_list params in
    let body, state = sink_expr body ~state in
    let handler, handler_state =
(*
Format.eprintf "Starting handler %a\n%!" Continuation.print name;
*)
      sink_expr handler ~state:(State.create ())
    in
(*
Format.eprintf "Finished handler %a\n%!" Continuation.print name;
*)
    let state =
      State.add_candidates_to_sink_from_handler_state state
        ~current_continuation:(name, recursive)
        ~handler_state
        ~except:params_set
    in
    let state = State.add_to_sink_from_state state ~from:handler_state in
    let state =
      State.add_candidates_to_sink state
        ~sink_into:[]
        ~candidates_to_sink:
          (Flambda.free_variables_of_specialised_args specialised_args)
    in
    Let_cont { name; body; handler =
      Handler { params; recursive; handler; specialised_args; } }, state
  | Apply _ | Apply_cont _ | Switch _ | Proved_unreachable ->
    let state =
      State.add_candidates_to_sink state
        ~sink_into:[]
        ~candidates_to_sink:(Flambda.free_variables expr)
    in
    expr, state

and sink_set_of_closures (set_of_closures : Flambda.set_of_closures) =
  let funs =
    Variable.Map.map (fun
            (function_decl : Flambda.function_declaration) ->
        Flambda.create_function_declaration
          ~params:function_decl.params
          ~continuation_param:function_decl.continuation_param
          ~body:(sink function_decl.body)
          ~stub:function_decl.stub
          ~dbg:function_decl.dbg
          ~inline:function_decl.inline
          ~specialise:function_decl.specialise
          ~is_a_functor:function_decl.is_a_functor)
      set_of_closures.function_decls.funs
  in
  let function_decls =
    Flambda.update_function_declarations
      set_of_closures.function_decls ~funs
  in
  Flambda.create_set_of_closures ~function_decls
    ~free_vars:set_of_closures.free_vars
    ~specialised_args:set_of_closures.specialised_args
    ~direct_call_surrogates:set_of_closures.direct_call_surrogates

and sink (expr : Flambda.t) =
  let expr, state = sink_expr expr ~state:(State.create ()) in
  let rec sink (expr : Flambda.t) : Flambda.t =
    match expr with
    | Let ({ var; body; } as let_expr) ->
      let body = sink body in
      if State.should_sink_let state var then
        body (* The let is to be moved into a handler. *)
      else
        let defining_expr = W.of_defining_expr_of_let let_expr in
        W.create_let_reusing_defining_expr var defining_expr body
    | Let_mutable { var; initial_value; contents_kind; body; } ->
      let body = sink body in
      Let_mutable { var; initial_value; contents_kind; body; }
    | Let_cont { name; body; handler = (Alias _) as handler; } ->
      let body = sink body in
      Let_cont { name; body; handler; }
    | Let_cont { name; body; handler =
        Handler { params; recursive; handler; specialised_args; } } ->
      let body = sink body in
      let handler =
        let handler = sink handler in
        let bindings = State.sunken_lets_for_handler state name in
(*
Format.eprintf "New bindings for top of %a outermost first is %a\n%!"
  Continuation.print name
  (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf " ")
    Variable.print) (List.map fst bindings);
*)
        List.fold_left (fun handler (var, defining_expr) ->
            W.create_let_reusing_defining_expr var defining_expr handler)
          handler
          (List.rev bindings)
      in
      Let_cont { name; body; handler =
        Handler { params; recursive; handler; specialised_args; } }
    | Apply _ | Apply_cont _ | Switch _ | Proved_unreachable -> expr
  in
(*
Format.eprintf "sink_lets starting with:@;%a\n" Flambda.print expr;
*)
let expr =
  sink expr
in
(*
Format.eprintf "sink_lets returning:@;%a\n" Flambda.print expr;
*)
expr

let run program =
  Flambda_iterators.map_exprs_at_toplevel_of_program program ~f:sink

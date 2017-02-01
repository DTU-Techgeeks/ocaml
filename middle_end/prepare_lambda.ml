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
[@@@ocaml.warning "-32"] (* XXX temporary *)

module L = Lambda

let stub_hack_prim_name = "*stub*"

let add_default_argument_wrappers lam =
  (* CR-someday mshinwell: Temporary hack to mark default argument wrappers
     as stubs.  Other possibilities:
     1. Change L.inline_attribute to add another ("stub") case;
     2. Add a "stub" field to the Lfunction record. *)
  let stubify body : L.lambda =
    let stub_prim =
      Primitive.simple ~name:stub_hack_prim_name
        ~arity:1 ~alloc:false
    in
    Lprim (Pccall stub_prim, [body], Location.none)
  in
  let defs_are_all_functions (defs : (_ * L.lambda) list) =
    List.for_all (function (_, L.Lfunction _) -> true | _ -> false) defs
  in
  let f (lam : L.lambda) : L.lambda =
    match lam with
    | Llet (( Strict | Alias | StrictOpt), _k, id,
        Lfunction {kind; params; body = fbody; attr; loc}, body) ->
      begin match
        Simplif.split_default_wrapper id kind params fbody attr loc
          ~create_wrapper_body:stubify
      with
      | [fun_id, def] -> Llet (Alias, Pgenval, fun_id, def, body)
      | [fun_id, def; inner_fun_id, def_inner] ->
        Llet (Alias, Pgenval, inner_fun_id, def_inner,
              Llet (Alias, Pgenval, fun_id, def, body))
      | _ -> assert false
      end
    | Lletrec (defs, body) as lam ->
      if defs_are_all_functions defs then
        let defs =
          List.flatten
            (List.map
               (function
                 | (id, L.Lfunction {kind; params; body; attr; loc}) ->
                   Simplif.split_default_wrapper id kind params body attr loc
                     ~create_wrapper_body:stubify
                 | _ -> assert false)
               defs)
        in
        Lletrec (defs, body)
      else lam
    | lam -> lam
  in
  L.map f lam

type block_type = Normal | Float

type letrec = {
  blocks : (Ident.t * block_type * int) list;
  (* CR pchambart: Should we preallocate with the tag ?
     How to get the tag for cases involving duprecord ? *)
  consts : (Ident.t * L.structured_constant) list;
  pre : Lambda.lambda -> Lambda.lambda;
  effects : Lambda.lambda;
  functions : (Ident.t * Lambda.lfunction) list;
}

let lsequence (lam1, lam2) : L.lambda =
  let seq = Ident.create "sequence" in
  Llet (Strict, Pgenval, seq, lam1, lam2)

let update_dummy var expr =
  let loc = Location.none in
  let desc =
    Primitive.simple ~name:"caml_update_dummy" ~arity:2 ~alloc:true
  in
  L.Lprim (Pccall desc, [L.Lvar var; expr], loc)

let build_block var size block_type expr letrec =
  let blocks =
    (var, block_type, size) :: letrec.blocks
  in
  let effects : Lambda.lambda =
    lsequence (update_dummy var expr, letrec.effects)
  in
  { letrec with blocks; effects }

let rec prepare_letrec recursive_set current_var (lam:Lambda.lambda) letrec =
  let module T = Types in
  match lam with
  | Lfunction funct ->
    { letrec with functions = (current_var, funct) :: letrec.functions }
  | Lprim (Pduprecord (kind, size), _, _) -> begin
    match kind with
    | T.Record_regular | T.Record_inlined _ ->
      build_block current_var size Normal lam letrec
    | T.Record_extension ->
      build_block current_var (size + 1) Normal lam letrec
    | T.Record_unboxed _ ->
      assert false
    | T.Record_float ->
      build_block current_var size Float lam letrec
    end
  | Lprim(Pmakeblock _, args, _)
  | Lprim (Pmakearray ((Paddrarray|Pintarray), _), args, _) ->
    build_block current_var (List.length args) Normal lam letrec
  | Lprim (Pmakearray (Pfloatarray, _), args, _) ->
    build_block current_var (List.length args) Float lam letrec
  | Lconst const ->
    { letrec with consts = (current_var, const) :: letrec.consts }
  | Llet (Variable, k, id, def, body) ->
    let letrec = prepare_letrec recursive_set current_var body letrec in
    let pre tail : Lambda.lambda =
      Llet (Variable, k, id, def, letrec.pre tail)
    in
    { letrec with pre }

  | Llet ((Strict | Alias | StrictOpt) as let_kind, k, id, def, body) ->
    let free_vars = Lambda.free_variables def in
    if Ident.Set.is_empty (Ident.Set.inter free_vars recursive_set) then
      (* Non recursive let *)
      let letrec = prepare_letrec recursive_set current_var body letrec in
      let pre tail : Lambda.lambda =
        Llet (let_kind, k, id, def, letrec.pre tail)
      in
      { letrec with pre }
    else
      let letrec =
        prepare_letrec (Ident.Set.add id recursive_set)
          current_var body letrec
      in
      prepare_letrec recursive_set id def letrec
  | Lsequence (_lam1, _lam2) ->
    (* Eliminated by prepare *)
    assert false
  | Levent (body, event) ->
    let letrec = prepare_letrec recursive_set current_var body letrec in
    { letrec with effects = Levent (letrec.effects, event) }
  | Lletrec (bindings, body) ->
    let free_vars =
      List.fold_left (fun set (_, def) -> Ident.Set.union (Lambda.free_variables def) set)
        Ident.Set.empty
        bindings
    in
    if Ident.Set.is_empty (Ident.Set.inter free_vars recursive_set) then
      (* Non recursive relative to top-level letrec *)
      let letrec = prepare_letrec recursive_set current_var body letrec in
      let pre tail : Lambda.lambda =
        Lletrec (bindings, letrec.pre tail)
      in
      { letrec with pre }
    else
      let recursive_set =
        Ident.Set.union recursive_set
          (Ident.Set.of_list (List.map fst bindings))
      in
      let letrec =
        List.fold_right (fun (id, def) letrec -> prepare_letrec recursive_set id def letrec)
          bindings
          letrec
      in
      prepare_letrec recursive_set current_var body letrec
  | _ ->
    let pre tail : Lambda.lambda =
      Llet (Strict, Pgenval, current_var, lam, letrec.pre tail)
    in
    { letrec with pre }

let dissect_letrec ~bindings ~body =
(*
  Format.printf "dissect@ %a@.@."
    Printlambda.lambda (L.Lletrec (bindings, Lconst (Const_pointer 0)));
*)
  let recursive_set =
    Ident.Set.of_list (List.map fst bindings)
  in

  let letrec =
    List.fold_right (fun (id, def) letrec -> prepare_letrec recursive_set id def letrec)
      bindings
      { blocks = [];
        consts = [];
        pre = (fun x -> x);
        effects = body;
        functions = [] }
  in
  let preallocations =
    let loc = Location.none in
    List.map (fun (id, block_type, size) ->
      let fn =
        match block_type with
        | Normal -> "caml_alloc_dummy"
        | Float -> "caml_alloc_dummy_float"
      in
      let desc = Primitive.simple ~name:fn ~arity:1 ~alloc:true in
      let size : L.lambda = Lconst (Const_base (Const_int size)) in
      id, L.Lprim (Pccall desc, [size], loc))
      letrec.blocks
  in
  let functions =
    match letrec.functions with
    | [] ->
      letrec.effects
    | _ :: _ ->
      let functions =
        List.map (fun (id, lfun) -> id, L.Lfunction lfun) letrec.functions
      in
      L.Lletrec (functions, letrec.effects)
  in
  let with_preallocations =
    List.fold_left
      (fun body (id, binding) ->
         L.Llet (Strict, Pgenval, id, binding, body))
      functions
      preallocations
  in
  let with_non_rec =
    letrec.pre with_preallocations
  in
  let with_constants =
    List.fold_left
      (fun body (id, const) ->
         L.Llet (Strict, Pgenval, id, Lconst const, body))
      with_non_rec
      letrec.consts
  in
(*
  Format.printf "dissected@ %a@.@."
    Printlambda.lambda with_constants;
*)
  with_constants

module Env : sig
  type t

  val create : current_unit_id:Ident.t -> t

  val current_unit_id : t -> Ident.t

  val add_mutable : t -> Ident.t -> t
  val is_mutable : t -> Ident.t -> bool

  val add_current_exception_continuation : t -> int -> t
  val add_continuation : t -> int -> t

  val required_poptrap_for_staticraise : t -> int -> int list
end = struct
  type t = {
    current_unit_id : Ident.t;
    mutables : Ident.Set.t;
    current_exception_continuation : int list;
    current_exception_depth : int;
    handler_exception_continuation : int Numbers.Int.Map.t; (* exception depth *)
  }

  let create ~current_unit_id =
    { current_unit_id;
      mutables = Ident.Set.empty;
      current_exception_continuation = [];
      current_exception_depth = 0;
      handler_exception_continuation = Numbers.Int.Map.empty;
    }

  let current_unit_id t = t.current_unit_id

  let add_mutable t id =
    assert (not (Ident.Set.mem id t.mutables));
    { t with mutables = Ident.Set.add id t.mutables; }

  let is_mutable t id =
    Ident.Set.mem id t.mutables

  let add_current_exception_continuation t cont =
    { t with
      current_exception_continuation =
        cont :: t.current_exception_continuation;
      current_exception_depth = 1 + t.current_exception_depth;
    }

  let add_continuation t cont =
    { t with
      handler_exception_continuation =
        Numbers.Int.Map.add cont t.current_exception_depth
          t.handler_exception_continuation;
    }

  let required_poptrap_for_staticraise t cont =
    let continuation_depth =
      Numbers.Int.Map.find cont t.handler_exception_continuation
    in
    let number_of_required_poptraps =
      t.current_exception_depth - continuation_depth
    in
    let head, _ =
      Misc.Stdlib.List.split_at number_of_required_poptraps
        t.current_exception_continuation
    in
    head

end

let sequence (lam1, lam2) =
  let ident = Ident.create "sequence" in
  L.Llet (Strict, Pgenval, ident, lam1, lam2)

let rec simplify_primitive env (prim : L.primitive) args loc =
  match prim, args with
  | (Pdivint Safe | Pmodint Safe
      | Pdivbint { is_safe = Safe } | Pmodbint { is_safe = Safe }),
    [arg1; arg2]
      when not !Clflags.fast -> (* not -unsafe *)
    let numerator = Ident.create "numerator" in
    let denominator = Ident.create "denominator" in
    let zero = Ident.create "zero" in
    let is_zero = Ident.create "is_zero" in
    let exn = Ident.create "division_by_zero" in
    let zero_const : Lambda.structured_constant =
      match prim with
      | Pdivint _ | Pmodint _ ->
        Const_base (Const_int 0)
      | Pdivbint { size = Pint32 } | Pmodbint { size = Pint32 } ->
        Const_base (Const_int32 0l)
      | Pdivbint { size = Pint64 } | Pmodbint { size = Pint64 } ->
        Const_base (Const_int64 0L)
      | Pdivbint { size = Pnativeint } | Pmodbint { size = Pnativeint } ->
        Const_base (Const_nativeint 0n)
      | _ -> assert false
    in
    let prim : Lambda.primitive =
      match prim with
      | Pdivint _ -> Pdivint Unsafe
      | Pmodint _ -> Pmodint Unsafe
      | Pdivbint { size } -> Pdivbint { size; is_safe = Unsafe }
      | Pmodbint { size } -> Pmodbint { size; is_safe = Unsafe }
      | _ -> assert false
    in
    let comparison : Lambda.primitive =
      match prim with
      | Pdivint _ | Pmodint _ -> Pintcomp Ceq
      | Pdivbint { size } | Pmodbint { size } -> Pbintcomp (size, Ceq)
      | _ -> assert false
    in
    let expr =
      L.Llet (Strict, Pgenval, zero, Lconst zero_const,
        (Llet (Strict, Pgenval, exn, Lvar Predef.ident_division_by_zero,
          (Llet (Strict, Pgenval, denominator, arg2,
            (Llet (Strict, Pgenval, numerator, arg1,
              (Llet (Strict, Pgenval, is_zero,
                (Lprim (comparison, [L.Lvar zero; L.Lvar denominator], loc)),
                (Lifthenelse (Lvar is_zero,
                  Lprim (Praise Raise_regular, [L.Lvar exn], loc),
                  (* CR-someday pchambart: find the right event.
                      mshinwell: I briefly looked at this, and couldn't
                      figure it out.
                      lwhite: I don't think any of the existing events
                      are suitable. I had to add a new one for a similar
                      case in the array data types work.
                      mshinwell: deferred CR *)
                  Lprim (prim, [L.Lvar numerator; L.Lvar denominator],
                    loc))))))))))))
    in
    prepare env expr (fun lam -> lam)
  | (Pdivint Safe | Pmodint Safe
      | Pdivbint { is_safe = Safe } | Pmodbint { is_safe = Safe }), _
      when not !Clflags.fast ->
    Misc.fatal_error "Pdivint / Pmodint must have exactly two arguments"
  | Psequor, [arg1; arg2] ->
    let const_true = Ident.create "const_true" in
    let cond = Ident.create "cond_sequor" in
    prepare env (
      L.Llet (Strict, Pgenval, const_true, Lconst (Const_base (Const_int 1)),
        (L.Llet (Strict, Pgenval, cond, arg1,
          (Lifthenelse (Lvar cond, Lvar const_true, arg2))))))
      (fun lam -> lam)
  | Psequand, [arg1; arg2] ->
    let const_false = Ident.create "const_false" in
    let cond = Ident.create "cond_sequand" in
    (* CR mshinwell: This recursion is a bit ugly.  Factor out a helper
       function for constructing if-then-else-like switches? *)
    prepare env (
      L.Llet (Strict, Pgenval, const_false, Lconst (Const_base (Const_int 0)),
        (L.Llet (Strict, Pgenval, cond, arg1,
          (Lifthenelse (Lvar cond, arg2, Lvar const_false))))))
      (fun lam -> lam)
  | (Psequand | Psequor), _ ->
    Misc.fatal_error "Psequand / Psequor must have exactly two arguments"
  | Pidentity, [arg] -> arg
  | Pdirapply, [funct; arg]
  | Prevapply, [arg; funct] ->
    let apply : L.lambda_apply =
      { ap_func = funct;
        ap_args = [arg];
        ap_loc = loc;
        ap_should_be_tailcall = false;
        (* CR-someday lwhite: it would be nice to be able to give
           inlined attributes to functions applied with the application
           operators. *)
        ap_inlined = Default_inline;
        ap_specialised = Default_specialise;
      }
    in
    L.Lapply apply
  | _, _ -> L.Lprim (prim, args, loc)

and prepare env (lam : L.lambda) (k : L.lambda -> L.lambda) =
  match lam with
  | Lvar id ->
    (* The special [Pread_mutable] primitive eases the translation to
       [Read_mutable] in Flambda. *)
    if Env.is_mutable env id then
      k (Lprim (Pread_mutable id, [], Location.none))
    else
      k lam
  | Lconst _ -> k lam
  | Lapply apply ->
    prepare env apply.ap_func (fun ap_func ->
      prepare_list env apply.ap_args (fun ap_args ->
        k (L.Lapply {
          ap_func;
          ap_args;
          ap_loc = apply.ap_loc;
          ap_should_be_tailcall = apply.ap_should_be_tailcall;
          ap_inlined = apply.ap_inlined;
          ap_specialised = apply.ap_specialised;
        })))
  | Lfunction func ->
    prepare env func.body (fun body ->
      k (L.Lfunction {
        kind = func.kind;
        params = func.params;
        body;
        attr = func.attr;
        loc = func.loc;
      }))
  | Llet (let_kind, value_kind, id, defining_expr, body) ->
    prepare env defining_expr (fun defining_expr ->
      let env =
        match let_kind with
        | Strict | StrictOpt | Alias -> env
        | Variable -> Env.add_mutable env id
      in
      prepare env body (fun body ->
        k (L.Llet (let_kind, value_kind, id, defining_expr, body))))
  | Lletrec (bindings, body) ->
    let idents, bindings = List.split bindings in
    prepare_list env bindings (fun bindings ->
      let bindings = List.combine idents bindings in
      prepare env body (fun body ->
        k (dissect_letrec ~bindings ~body)))
  | Lprim (Pfield _, [Lprim (Pgetglobal id, [],_)], _)
      when Ident.same id (Env.current_unit_id env) ->
    Misc.fatal_error "[Pfield (Pgetglobal ...)] for the current compilation \
      unit is forbidden upon entry to the middle end"
  | Lprim (Psetfield (_, _, _), [Lprim (Pgetglobal _, [], _); _], _) ->
    Misc.fatal_error "[Psetfield (Pgetglobal ...)] is \
      forbidden upon entry to the middle end"
  | Lprim (prim, args, loc) ->
    prepare_list env args (fun args ->
      k (simplify_primitive env prim args loc))
  | Lswitch (scrutinee, switch) ->
    prepare env scrutinee (fun scrutinee ->
      let const_nums, sw_consts = List.split switch.sw_consts in
      let block_nums, sw_blocks = List.split switch.sw_blocks in
      prepare_option env switch.sw_failaction (fun sw_failaction ->
        prepare_list env sw_consts (fun sw_consts ->
          prepare_list env sw_blocks (fun sw_blocks ->
            let sw_failaction, wrap_switch =
              match sw_failaction with
              | None -> None, (fun lam -> lam)
              | Some failaction ->
                let failaction_cont = L.next_raise_count () in
                let wrap_switch lam : L.lambda =
                  Lstaticcatch (lam, (failaction_cont, []), failaction)
                in
                Some (L.Lstaticraise (failaction_cont, [])), wrap_switch
            in
            let consts_switch : L.lambda_switch =
              { sw_numconsts = switch.sw_numconsts;
                sw_consts = List.combine const_nums sw_consts;
                sw_numblocks = 0;
                sw_blocks = [];
                sw_failaction;
              }
            in
            let blocks_switch : L.lambda_switch =
              { sw_numconsts = switch.sw_numblocks;
                sw_consts = List.combine block_nums sw_blocks;
                sw_numblocks = 0;
                sw_blocks = [];
                sw_failaction;
              }
            in
            let consts_switch : L.lambda =
              L.Lswitch (scrutinee, consts_switch)
            in
            let blocks_switch : L.lambda =
              L.Lswitch (Lprim (Pgettag, [scrutinee], Location.none),
               blocks_switch)
            in
            let isint_switch : L.lambda_switch =
              { sw_numconsts = 2;
                sw_consts = [0, blocks_switch; 1, consts_switch];
                sw_numblocks = 0;
                sw_blocks = [];
                sw_failaction = None;
              }
            in
            k (wrap_switch (
              L.Lswitch (Lprim (Pisint, [scrutinee], Location.none),
                isint_switch)))))))
  | Lstringswitch (scrutinee, cases, default, loc) ->
    prepare env scrutinee (fun scrutinee ->
      let patterns, cases = List.split cases in
      prepare_list env cases (fun cases ->
        let cases = List.combine patterns cases in
        prepare_option env default (fun default ->
          k (L.Lstringswitch (scrutinee, cases, default, loc)))))
  | Lstaticraise (cont, args) ->
    prepare_list env args (fun args ->
      k (L.Lstaticraise (cont, args)))
  | Lstaticcatch (body, (cont, args), handler) ->
    let env_body = Env.add_continuation env cont in
    prepare env_body body (fun body ->
      prepare env handler (fun handler ->
        k (L.Lstaticcatch (body, (cont, args), handler))))
  | Ltrywith (body, id, handler) ->
    prepare env body (fun body ->
      prepare env handler (fun handler ->
        k (L.Ltrywith (body, id, handler))))
  | Lifthenelse (cond, ifso, ifnot) ->
    prepare env cond (fun cond ->
      prepare env ifso (fun ifso ->
        prepare env ifnot (fun ifnot ->
          let switch : Lambda.lambda_switch =
            { sw_numconsts = 2;
              sw_consts = [0, ifnot; 1, ifso];
              sw_numblocks = 0;
              sw_blocks = [];
              sw_failaction = None;
            }
          in
          k (L.Lswitch (cond, switch)))))
  | Lsequence (lam1, lam2) ->
    let ident = Ident.create "sequence" in
    prepare env (L.Llet (Strict, Pgenval, ident, lam1, lam2)) k
  | Lwhile (cond, body) ->
    let cont = L.next_raise_count () in
    let cond_result = Ident.create "cond_result" in
    let lam : L.lambda =
      Lstaticcatch (
        Lstaticraise (cont, []),
        (cont, []),
        Llet (Strict, Pgenval, cond_result, cond,
          Lifthenelse (Lvar cond_result,
            Lsequence (
              body,
              Lstaticraise (cont, [])),
            Lconst (Const_base (Const_int 0)))))
    in
    prepare env lam k
  | Lfor (ident, start, stop, dir, body) ->
    let loc = Location.none in
    let cont = L.next_raise_count () in
    let stop_ident = Ident.create "stop" in
    let test =
      match dir with
      | Upto -> L.Lprim (Pintcomp Cle, [L.Lvar ident; L.Lvar stop_ident], loc)
      | Downto -> L.Lprim (Pintcomp Cge, [L.Lvar ident; L.Lvar stop_ident], loc)
    in
    let one : L.lambda = Lconst (Const_base (Const_int 1)) in
    let next_value_of_counter =
      match dir with
      | Upto -> L.Lprim (Paddint, [L.Lvar ident; one], loc)
      | Downto -> L.Lprim (Psubint, [L.Lvar ident; one], loc)
    in
    let lam : L.lambda =
      (* CR mshinwell: check evaluation order of start vs. end *)
      Llet (Strict, Pgenval, stop_ident, stop,
        Lstaticcatch (
          Lstaticraise (cont, [start]),
          (cont, [ident]),
          Lifthenelse (test,
            Lsequence (
              body,
              Lstaticraise (cont, [next_value_of_counter])),
            Lconst (Const_base (Const_int 0)))))
    in
    prepare env lam k
  | Lassign (ident, lam) ->
    if not (Env.is_mutable env ident) then begin
      Misc.fatal_errorf "Lassign on non-mutable variable %a"
        Ident.print ident
    end;
    prepare env lam (fun lam -> k (L.Lassign (ident, lam)))
  | Lsend (meth_kind, meth, obj, args, loc) ->
    prepare env meth (fun meth ->
      prepare env obj (fun obj ->
        prepare_list env args (fun args ->
          k (L.Lsend (meth_kind, meth, obj, args, loc)))))
  | Levent (body, event) ->
    prepare env body (fun body ->
      k (L.Levent (body, event)))
  | Lifused _ ->
    (* [Lifused] is used to mark that this expression should be alive only if
       an identifier is.  Every use should have been removed by
       [Simplif.simplify_lets], either by replacing by the inner expression,
       or by completely removing it (replacing by unit). *)
    Misc.fatal_error "[Lifused] should have been removed by \
        [Simplif.simplify_lets]"

and prepare_list env lams k =
  match lams with
  | [] -> k []
  | lam::lams ->
    prepare env lam (fun lam ->
      prepare_list env lams (fun lams -> k (lam::lams)))

and prepare_option env lam_opt k =
  match lam_opt with
  | None -> k None
  | Some lam -> prepare env lam (fun lam -> k (Some lam))

let run lam =
  let current_unit_id =
    Compilation_unit.get_persistent_ident
      (Compilation_unit.get_current_exn ())
  in
  let env = Env.create ~current_unit_id in
  let lam = add_default_argument_wrappers lam in
  prepare env lam (fun lam -> lam)

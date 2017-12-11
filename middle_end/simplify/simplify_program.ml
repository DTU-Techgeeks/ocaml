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

module E = Simplify_env_and_result.Env
module R = Simplify_env_and_result.Result
module T = Flambda_type

module Float = Numbers.Float
module Int32 = Numbers.Int32
module Int64 = Numbers.Int64
module Of_kind_value = Flambda_static.Of_kind_value
module Program = Flambda_static.Program
module Program_body = Flambda_static.Program_body
module Static_part = Flambda_static.Static_part

type 'a or_invalid =
  | Ok of 'a
  | Invalid

let simplify_static_part env (static_part : Static_part.t) : _ or_invalid =
  let importer = E.importer env in
  let type_of_name = E.type_of_name env in
  let simplify_float_fields (mut : Flambda_primitive.mutable_or_immutable)
        fields =
    let or_unknown field =
      match mut with
      | Immutable -> Some field
      | Mutable -> None
    in
    let done_something, fields_rev =
      List.fold_left
        (fun (done_something, fields_rev) (field : _ Static_part.or_variable) ->
          match field with
          | Const f -> done_something, ((field, or_unknown f) :: fields_rev)
          | Var var ->
            let ty = E.find_var env var in
            begin match T.prove_naked_float ~importer ~type_of_name ty with
            | Not_all_values_known ->
              done_something, ((field, None) :: fields_rev)
            | Exactly fs ->
              begin match Float.Set.get_singleton fs with
              | None ->
                done_something, ((field, None) :: fields_rev)
              | Some f ->
                true, ((Static_part.Const f, or_unknown f) :: fields_rev)
              end
            end)
        (false, [])
        fields
    in
    let static_part_fields, fields = List.split (List.rev fields_rev) in
    done_something, static_part_fields, fields
  in
  match static_part with
  | Block (tag, mut, fields) ->
    let or_unknown scanning ty =
      match mut with
      | Immutable -> ty
      | Mutable -> T.any_value scanning Other
    in
    let fields_and_types =
      List.map (fun (field : Of_kind_value.t) ->
          match field with
          | Symbol sym ->
            let ty = E.find_symbol env sym in
            field, or_unknown Definitely_immediate ty
          | Tagged_immediate imm ->
            field, or_unknown Definitely_immediate (T.this_tagged_immediate imm)
          | Dynamically_computed var ->
            let ty = E.find_var env var in
            let ty, canonical_name =
              T.resolve_aliases ~importer ~type_of_name ty
            in
            let canonical_var =
              match canonical_name with
              | Some (Var var) -> var
              | (Some (Symbol _)) | None -> var
            in
            begin match canonical_name with
            | Some (Symbol sym) ->
              Of_kind_value.Symbol sym, or_unknown Definitely_immediate ty
            | (Some (Var _)) | None ->
              match T.prove_tagged_immediate ~importer ~type_of_name ty with
              | Proved (Exactly imms) ->
                begin match Immediate.Set.get_singleton imms with
                | None ->
                  Of_kind_value.Dynamically_computed canonical_var,
                    or_unknown Must_scan ty
                | Some imm ->
                  Of_kind_value.Tagged_immediate imm,
                    or_unknown Definitely_immediate (T.this_tagged_immediate imm)
                end
              | Proved Not_all_values_known
              | Invalid ->
                (* Note that [Invalid] does not propagate here: all it means
                   is that this is something of kind [Value], but not a
                   tagged immediate.  Such things are still legal in this
                   context. *)
                Of_kind_value.Dynamically_computed var, or_unknown Must_scan ty
            end)
        fields
    in
    let fields, field_types = List.split fields_and_types in
    assert (match mut with
      | Immutable -> true
      | Mutable ->
        List.for_all (fun ty -> not (T.is_known ~importer ~type_of_name ty))
          field_types);
    let ty = T.block tag (Array.of_list field_types) in
    Ok (Static_part.Block (tag, mut, fields), ty)
  | Set_of_closures set ->
    let r = R.create () in
    let set, ty, _r = Simplify_named.simplify_set_of_closures env r set in
    Ok (Static_part.Set_of_closures set, ty)
  | Closure (sym, closure_id) ->
    let ty = E.find_symbol env sym in
    begin match T.prove_sets_of_closures ~importer ~type_of_name ty with
    | Proved (Exactly sets) ->
      let closure_ty =
        T.Joined_sets_of_closures.type_for_closure_id sets closure_id
      in
      Ok (static_part, closure_ty)
    | Proved Not_all_values_known ->
      Ok (static_part, T.any_value Must_scan Other)
    | Invalid -> Invalid
    end
  | Boxed_float (Const f) -> Ok (static_part, T.this_boxed_float f)
  | Mutable_string { initial_value = Const str; } ->
    Ok (static_part, T.mutable_string ~size:(String.length str))
  | Immutable_string (Const str) ->
    let ty = T.this_immutable_string str in
    Ok (static_part, ty)
  | Boxed_float (Var var) ->
    let ty = E.find_var env var in
    (* CR mshinwell: Add e.g. [T.prove_unique_boxed_float] -- should save
       code here *)
    begin match T.prove_boxed_float ~importer ~type_of_name ty with
    | Proved (Exactly fs) ->
      begin match Float.Set.get_singleton fs with
      | Some f ->
        Ok (Static_part.Boxed_float (Const f), T.this_boxed_float f)
      | None ->
        Ok (static_part, T.any_boxed_float ())
      end
    | Proved Not_all_values_known -> Ok (static_part, T.any_boxed_float ())
    | Invalid -> Invalid
    end
  | Boxed_int32 (Const n) -> Ok (static_part, T.this_boxed_int32 n)
  | Boxed_int32 (Var var) ->
    let ty = E.find_var env var in
    begin match T.prove_boxed_int32 ~importer ~type_of_name ty with
    | Proved (Exactly is) ->
      begin match Int32.Set.get_singleton is with
      | Some i ->
        Ok (Static_part.Boxed_int32 (Const i), T.this_boxed_int32 i)
      | None ->
        Ok (static_part, T.any_boxed_int32 ())
      end
    | Proved Not_all_values_known -> Ok (static_part, T.any_boxed_int32 ())
    | Invalid -> Invalid
    end
  | Boxed_int64 (Const n) -> Ok (static_part, T.this_boxed_int64 n)
  | Boxed_int64 (Var var) ->
    let ty = E.find_var env var in
    begin match T.prove_boxed_int64 ~importer ~type_of_name ty with
    | Proved (Exactly is) ->
      begin match Int64.Set.get_singleton is with
      | Some i ->
        Ok (Static_part.Boxed_int64 (Const i), T.this_boxed_int64 i)
      | None ->
        Ok (static_part, T.any_boxed_int64 ())
      end
    | Proved Not_all_values_known -> Ok (static_part, T.any_boxed_int64 ())
    | Invalid -> Invalid
    end
  | Boxed_nativeint (Const n) -> Ok (static_part, T.this_boxed_nativeint n)
  | Boxed_nativeint (Var var) ->
    let ty = E.find_var env var in
    begin match T.prove_boxed_nativeint ~importer ~type_of_name ty with
    | Proved (Exactly is) ->
      begin match Targetint.Set.get_singleton is with
      | Some i ->
        Ok (Static_part.Boxed_nativeint (Const i), T.this_boxed_nativeint i)
      | None ->
        Ok (static_part, T.any_boxed_nativeint ())
      end
    | Proved Not_all_values_known -> Ok (static_part, T.any_boxed_nativeint ())
    | Invalid -> Invalid
    end
  | Mutable_float_array { initial_value = fields; } ->
    let done_something, initial_value, fields =
      simplify_float_fields Mutable fields
    in
    let ty = T.mutable_float_array ~size:(List.length fields) in
    if not done_something then Ok (static_part, ty)
    else Ok (Static_part.Mutable_float_array { initial_value; }, ty)
  | Immutable_float_array fields ->
    let done_something, static_part_fields, fields =
      simplify_float_fields Immutable fields
    in
    let fields =
      List.map (fun field ->
          match field with
          | None -> T.any_naked_float ()
          | Some f -> T.this_naked_float f)
        fields
    in
    let ty = T.immutable_float_array (Array.of_list fields) in
    if not done_something then Ok (static_part, ty)
    else Ok (Static_part.Immutable_float_array static_part_fields, ty)
  | Mutable_string { initial_value = Var var; } ->
    let ty = E.find_var env var in
    begin match T.prove_string ~importer ~type_of_name ty with
    | Proved (Exactly strs) ->
      begin match T.String_info.Set.get_singleton strs with
      | Some str ->
        let ty = T.mutable_string ~size:str.size in
        begin match str.contents with
        | Unknown_or_mutable -> Ok (static_part, ty)
        | Contents str ->
          Ok (Static_part.Mutable_string { initial_value = Const str; }, ty)
        end
      | None -> Ok (static_part, T.any_value Must_scan Other)
      end
    | Proved Not_all_values_known ->
      Ok (static_part, T.any_value Must_scan Other)
    | Invalid -> Invalid
    end
  | Immutable_string (Var var) ->
    let ty = E.find_var env var in
    begin match T.prove_string ~importer ~type_of_name ty with
    | Proved (Exactly strs) ->
      begin match T.String_info.Set.get_singleton strs with
      | Some str ->
        begin match str.contents with
        | Contents s ->
          let ty = T.this_immutable_string s in
          Ok (Static_part.Immutable_string (Const s), ty)
        | Unknown_or_mutable ->
          let ty = T.immutable_string ~size:str.size in
          Ok (static_part, ty)
        end
      | None -> Ok (static_part, T.any_value Must_scan Other)
      end
    | Proved Not_all_values_known ->
      Ok (static_part, T.any_value Must_scan Other)
    | Invalid -> Invalid
    end

let simplify_static_structure initial_env (recursive : Flambda.recursive) str =
  let unreachable, env, str =
    List.fold_left
      (fun ((now_unreachable, env, str) as acc) (sym, static_part) ->
        if now_unreachable then
          acc
        else
          match simplify_static_part initial_env static_part with
          | Ok (static_part, ty) ->
            let env =
              match recursive with
              | Non_recursive -> E.add_symbol env sym ty
              | Recursive -> E.redefine_symbol env sym ty
            in
            false, env, ((sym, static_part) :: str)
          | Invalid ->
            true, env, str)
      (false, initial_env, [])
      str
  in
  unreachable, env, List.rev str

let initial_environment_for_recursive_symbols env
      (defn : Program_body.definition) =
  let env =
    List.fold_left (fun env (symbol, _static_part) ->
        E.add_symbol env symbol (T.unresolved_symbol symbol))
      env defn.static_structure
  in
  let _unreachable, env, _str =
    simplify_static_structure env Recursive defn.static_structure
  in
  env

let simplify_define_symbol env (recursive : Flambda.recursive)
      (defn : Program_body.definition)
      : Program_body.definition * E.t =
  let env, computation =
    match defn.computation with
    | None -> env, defn.computation
    | Some computation ->
      let arity =
        List.map (fun (_var, kind) -> kind) computation.computed_values
      in
      let name = computation.return_cont in
      let return_cont_approx =
        Continuation_approx.create_unknown ~name ~arity
      in
      let expr, r, _continuation_uses =
        let env = E.add_continuation env name return_cont_approx in
        let r = R.create () in
        let descr =
          let symbol_names =
            List.map (fun (sym, _) ->
                Format.asprintf "%a" Symbol.print sym)
              defn.static_structure
          in
          Printf.sprintf "Toplevel binding(s) of: %s"
            (String.concat "+" symbol_names)
        in
        Simplify.simplify_toplevel env r computation.expr ~continuation:name
          ~descr
      in
      (* CR mshinwell: Add unboxing of the continuation here.  This will look
         like half of Unbox_returns (same analysis and the same thing to
         happen to [expr]; but instead of generating a function wrapper, we
         need to do something else here).  Note that the linearity check
         for Unbox_returns will enable us to handle mutable returned values
         too. *)
      let args_types = R.continuation_args_types r name ~arity in
      assert (List.for_all2 (fun (_var, kind1) ty ->
          let kind2 =
            T.kind ~importer:(E.importer env)
              ~type_of_name:(E.type_of_name env)
              ty
          in
          Flambda_kind.equal kind1 kind2)
        computation.computed_values args_types);
      let env =
        List.fold_left2 (fun env (var, _kind) ty ->
            E.add_variable env var ty)
          env
          computation.computed_values args_types
      in
      let computation =
        match expr with
        | Apply_cont (cont, None, []) ->
          assert (Continuation.equal cont computation.return_cont);
          None
        | _ ->
          Some ({
            expr;
            return_cont = computation.return_cont;
            exception_cont = computation.exception_cont;
            computed_values = computation.computed_values;
          } : Program_body.computation)
      in
      env, computation
  in
  let env =
    match recursive with
    | Non_recursive -> env
    | Recursive -> initial_environment_for_recursive_symbols env defn
  in
  let unreachable, env, static_structure =
    simplify_static_structure env recursive defn.static_structure
  in
  let computation, static_structure =
    (* CR-someday mshinwell: We could imagine propagating an "unreachable"
       (if that's what [invalid ()] turns into, rather than a trap) back to
       previous [Define_symbol]s. *)
    if not unreachable then
      computation, static_structure
    else
      match computation with
      | None ->
        let computation : Program_body.computation =
          { expr = Flambda.Expr.invalid ();
            return_cont = Continuation.create ();
            exception_cont = Continuation.create ();
            computed_values = [];
          }
        in
        Some computation, []
      | Some computation ->
        let params =
          List.map (fun (var, kind) ->
              let param = Parameter.wrap var in
              Flambda.Typed_parameter.create_from_kind param kind)
            computation.computed_values
        in
        let expr : Flambda.Expr.t =
          Let_cont {
            body = computation.expr;
            handlers = Non_recursive {
              name = computation.return_cont;
              handler = {
                params;
                stub = false;
                is_exn_handler = false;
                handler = Flambda.Expr.invalid ();
              };
            };
          }
        in
        let new_return_cont =
          (* This continuation will never be called. *)
          Continuation.create ()
        in
        let computation : Program_body.computation =
          { expr;
            return_cont = new_return_cont;
            (* CR mshinwell: Think more about exception continuations here *)
            exception_cont = computation.exception_cont;
            computed_values = [];
          }
        in
        Some computation, []
  in
  let definition : Program_body.definition =
    { static_structure;
      computation;
    }
  in
  definition, env

let rec simplify_program_body env (body : Program_body.t) : Program_body.t =
  match body with
  | Define_symbol (defn, body) ->
    let defn, env = simplify_define_symbol env Non_recursive defn in
    let body = simplify_program_body env body in
    Define_symbol (defn, body)
  | Define_symbol_rec (defn, body) ->
    let defn, env = simplify_define_symbol env Recursive defn in
    let body = simplify_program_body env body in
    Define_symbol_rec (defn, body)
  | Root _ -> body

let simplify_program env ~backend (program : Program.t) =
  let module Backend = (val backend : Backend_intf.S) in
  let predef_exn_symbols = Backend.all_predefined_exception_symbols () in
  let env =
    Symbol.Set.fold (fun symbol env -> E.import_symbol env symbol)
      (Symbol.Set.union program.imported_symbols predef_exn_symbols)
      env
  in
  let body = simplify_program_body env program.body in
  { program with body; }

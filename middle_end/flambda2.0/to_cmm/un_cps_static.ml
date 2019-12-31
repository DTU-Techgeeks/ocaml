(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                        Guillaume Bury, OCamlPro                        *)
(*                                                                        *)
(*   Copyright 2019--2019 OCamlPro SAS                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-30-40-41-42"]

open! Flambda.Import

module C = struct
  include Cmm_helpers
  include Un_cps_helper
end

module Bound_symbols = Let_symbol.Bound_symbols
module Env = Un_cps_env
module SC = Flambda.Static_const
module R = Un_cps_result

(* CR mshinwell: Share these next functions with Un_cps.  Unfortunately
   there's a name clash with at least one of them ("symbol") with functions
   already in Un_cps_helper. *)
let symbol s =
  Linkage_name.to_string (Symbol.linkage_name s)

let tag_targetint t = Targetint.(add (shift_left t 1) one)

let targetint_of_imm i = Targetint.OCaml.to_targetint i.Immediate.value

let nativeint_of_targetint t =
  match Targetint.repr t with
  | Int32 i -> Nativeint.of_int32 i
  | Int64 i -> Int64.to_nativeint i

let filter_closure_vars env s =
  let used_closure_vars = Env.used_closure_vars env in
  let aux clos_var _bound_to =
    Var_within_closure.Set.mem clos_var used_closure_vars
  in
  Var_within_closure.Map.filter aux s

let todo () = failwith "Not yet implemented"
(* ----- End of functions to share ----- *)

let name_static _env = function
  | Name.Var v -> `Var v
  | Name.Symbol s -> `Data [C.symbol_address (symbol s)]

let const_static _env c =
  match (c : Simple.Const.t) with
  | Naked_immediate i ->
      [C.cint (nativeint_of_targetint (targetint_of_imm i))]
  | Tagged_immediate i ->
      [C.cint (nativeint_of_targetint (tag_targetint (targetint_of_imm i)))]
  | Naked_float f ->
      [C.cfloat (Numbers.Float_by_bit_pattern.to_float f)]
  | Naked_int32 i ->
      [C.cint (Nativeint.of_int32 i)]
  | Naked_int64 i ->
      if C.arch32 then todo() (* split int64 on 32-bit archs *)
      else [C.cint (Int64.to_nativeint i)]
  | Naked_nativeint t ->
      [C.cint (nativeint_of_targetint t)]

let simple_static env s =
  match (Simple.descr s : Simple.descr) with
  | Name n -> name_static env n
  | Const c -> `Data (const_static env c)

let static_value _env v =
  match (v : SC.Field_of_block.t) with
  | Symbol s -> C.symbol_address (symbol s)
  | Dynamically_computed _ -> C.cint 1n
  | Tagged_immediate i ->
      C.cint (nativeint_of_targetint (tag_targetint (targetint_of_imm i)))

let or_variable f default v cont =
  match (v : _ SC.or_variable) with
  | Const c -> f c cont
  | Var _ -> f default cont

let map_or_variable f default v =
  match (v : _ SC.or_variable) with
  | Const c -> f c
  | Var _ -> default

let make_update env kind symb var i =
  let e = Env.get_variable env var in
  let address = C.field_address symb i Debuginfo.none in
  C.store kind Lambda.Root_initialization address e

let rec static_block_updates symb env acc i = function
  | [] -> List.fold_left C.sequence C.void acc
  | sv :: r ->
      begin match (sv : SC.Field_of_block.t) with
      | Symbol _
      | Tagged_immediate _ ->
          static_block_updates symb env acc (i + 1) r
      | Dynamically_computed var ->
          let update = make_update env Cmm.Word_val symb var i in
          static_block_updates symb env (update :: acc) (i + 1) r
      end

let rec static_float_array_updates symb env acc i = function
  | [] -> List.fold_left C.sequence C.void acc
  | sv :: r ->
      begin match (sv : _ SC.or_variable) with
      | Const _ ->
          static_float_array_updates symb env acc (i + 1) r
      | Var var ->
          let update = make_update env Cmm.Double_u symb var i in
          static_float_array_updates symb env (update :: acc) (i + 1) r
      end

let static_boxed_number kind env s default emit transl v r =
  let name = symbol s in
  let aux x cont = emit (name, Cmmgen_state.Global) (transl x) cont in
  let wrapper =
    match (v : _ SC.or_variable) with
    | Const _ -> Fun.id
    | Var v ->
        let update = make_update env kind (C.symbol name) v 0 in
        C.sequence update
  in
  R.wrap_init wrapper (R.update_data (or_variable aux default v) r)

let get_whole_closure_symbol =
  let whole_closure_symb_count = ref 0 in
  (fun r ->
     match !r with
     | Some s -> s
     | None ->
         incr whole_closure_symb_count;
         let comp_unit = Compilation_unit.get_current_exn () in
         let linkage_name =
           Linkage_name.create @@
           Printf.sprintf ".clos_%d" !whole_closure_symb_count
         in
         let s = Symbol.create comp_unit linkage_name in
         r := Some s;
         s
  )

let rec static_set_of_closures env symbs set =
  let clos_symb = ref None in
  let fun_decls = Set_of_closures.function_decls set in
  let decls = Function_declarations.funs fun_decls in
  let elts = filter_closure_vars env (Set_of_closures.closure_elements set) in
  let layout = Env.layout env
      (List.map fst (Closure_id.Map.bindings decls))
      (List.map fst (Var_within_closure.Map.bindings elts))
  in
  let l, updates, length =
    fill_static_layout clos_symb symbs decls elts env [] C.void 0 layout
  in
  let header = C.cint (C.black_closure_header length) in
  let sdef = match !clos_symb with
    | None -> []
    | Some s -> C.define_symbol ~global:false (symbol s)
  in
  header :: sdef @ l, updates

and fill_static_layout s symbs decls elts env acc updates i = function
  | [] -> List.rev acc, updates, i
  | (j, slot) :: r ->
      let acc = fill_static_up_to j acc i in
      let acc, offset, updates =
        fill_static_slot s symbs decls elts env acc j updates slot
      in
      fill_static_layout s symbs decls elts env acc updates offset r

and fill_static_slot s symbs decls elts env acc offset updates slot =
  match (slot : Un_cps_closure.layout_slot) with
  | Infix_header ->
      let field = C.cint (C.infix_header (offset + 1)) in
      field :: acc, offset + 1, updates
  | Env_var v ->
      let fields, updates =
        match simple_static env (Var_within_closure.Map.find v elts) with
        | `Data fields -> fields, updates
        | `Var v ->
            let s = get_whole_closure_symbol s in
            let update =
              make_update env Cmm.Word_val (C.symbol (symbol s)) v offset
            in
            [C.cint 1n], C.sequence update updates
      in
      List.rev fields @ acc, offset + 1, updates
  | Closure c ->
      let decl = Closure_id.Map.find c decls in
      let symb = Closure_id.Map.find c symbs in
      let external_name = symbol symb in
      let code_name =
        Un_cps_closure.closure_code (Un_cps_closure.closure_name c)
      in
      let acc = List.rev (C.define_symbol ~global:true external_name) @ acc in
      let arity = List.length (Function_declaration.params_arity decl) in
      let tagged_arity = arity * 2 + 1 in
      (* We build here the **reverse** list of fields for the closure *)
      if arity = 1 || arity = 0 then begin
        let acc =
          C.cint (Nativeint.of_int tagged_arity) ::
          C.symbol_address code_name ::
          acc
        in
        acc, offset + 2, updates
      end else begin
        let acc =
          C.symbol_address code_name ::
          C.cint (Nativeint.of_int tagged_arity) ::
          C.symbol_address (C.curry_function_sym arity) ::
          acc
        in
        acc, offset + 3, updates
      end

and fill_static_up_to j acc i =
  if i = j then acc
  else fill_static_up_to j (C.cint 1n :: acc) (i + 1)

let static_const0 env r ~params_and_body (bound_symbols : Bound_symbols.t)
      (static_const : Static_const.t) =
  match bound_symbols, static_const with
  | Singleton s, Block (tag, _mut, fields) ->
      let name = symbol s in
      let tag = Tag.Scannable.to_int tag in
      let block_name = name, Cmmgen_state.Global in
      let header = C.block_header tag (List.length fields) in
      let static_fields = List.map (static_value env) fields in
      let block = C.emit_block block_name header static_fields in
      let e = static_block_updates (C.symbol name) env [] 0 fields in
      env, R.wrap_init (C.sequence e) (R.add_data block r)
  | Code_and_set_of_closures { code_ids = _; closure_symbols; },
    Code_and_set_of_closures { code; set_of_closures; } ->
      (* We cannot both build the environment and compile the functions in
         one traversal, as the bodies may contain direct calls to the code ids
         being defined *)
      let updated_env =
        Code_id.Map.fold
          (fun code_id SC.({ params_and_body = p; newer_version_of = _; }) env ->
            match (p : _ SC.or_deleted) with
            | Deleted -> env
            | Present p ->
                Function_params_and_body.pattern_match p
                  ~f:(fun ~return_continuation:_ _exn_k _ps ~body ~my_closure ->
                      let free_vars =
                        Name_occurrences.variables (Expr.free_names body)
                      in
                      (* Format.eprintf "Free vars: %a@." Variable.Set.print free_vars; *)
                      let needs_closure_arg =
                        Variable.Set.mem my_closure free_vars
                      in
                      let info : Env.function_info = { needs_closure_arg; } in
                      Env.add_function_info env code_id info))
          code
          env
      in
      let r =
        Code_id.Map.fold
          (fun code_id SC.({ params_and_body = p; newer_version_of = _; }) r ->
            match (p : _ SC.or_deleted) with
            | Deleted -> r
            | Present p ->
              let fun_symbol = Code_id.code_symbol code_id in
              let fun_name =
                Linkage_name.to_string (Symbol.linkage_name fun_symbol)
              in
              (* CR vlaviron: fix debug info *)
              let fundecl =
                C.cfunction (params_and_body updated_env fun_name
                  Debuginfo.none p)
              in
              R.add_function fundecl r)
          code
          r
      in
      begin match set_of_closures with
      | None -> updated_env, r
      | Some set ->
        let data, updates =
          static_set_of_closures env closure_symbols set
        in
        updated_env, R.wrap_init (C.sequence updates) (R.add_data data r)
      end
  | Singleton s, Boxed_float v ->
      let default = Numbers.Float_by_bit_pattern.zero in
      let transl = Numbers.Float_by_bit_pattern.to_float in
      env, static_boxed_number
        Cmm.Double_u env s default C.emit_float_constant transl v r
  | Singleton s, Boxed_int32 v ->
      env, static_boxed_number
        Cmm.Word_int env s 0l C.emit_int32_constant Fun.id v r
  | Singleton s, Boxed_int64 v ->
      env, static_boxed_number
        Cmm.Word_int env s 0L C.emit_int64_constant Fun.id v r
  | Singleton s, Boxed_nativeint v ->
      let default = Targetint.zero in
      let transl = nativeint_of_targetint in
      env, static_boxed_number
        Cmm.Word_int env s default C.emit_nativeint_constant transl v r
  | Singleton s, Immutable_float_array fields ->
      let name = symbol s in
      let aux = map_or_variable Numbers.Float_by_bit_pattern.to_float 0. in
      let static_fields = List.map aux fields in
      let float_array =
        C.emit_float_array_constant (name, Cmmgen_state.Global) static_fields
      in
      let e = static_float_array_updates (C.symbol name) env [] 0 fields in
      env, R.wrap_init (C.sequence e) (R.update_data float_array r)
  | Singleton s, Mutable_string { initial_value = str; }
  | Singleton s, Immutable_string str ->
      let name = symbol s in
      let data = C.emit_string_constant (name, Cmmgen_state.Global) str in
      env, R.update_data data r
  | Singleton _, Code_and_set_of_closures _ ->
      Misc.fatal_errorf "[Code_and_set_of_closures] cannot be bound by a \
          [Singleton] binding:@ %a"
        SC.print static_const
  | Code_and_set_of_closures _,
    (Block _ | Boxed_float _ | Boxed_int32 _ | Boxed_int64 _
      | Boxed_nativeint _ | Immutable_float_array _ | Mutable_string _
      | Immutable_string _) ->
      Misc.fatal_errorf "Only [Code_and_set_of_closures] can be bound by a \
          [Code_and_set_of_closures] binding:@ %a"
        SC.print static_const

let static_const env ~params_and_body (bound_symbols : Bound_symbols.t)
      (static_const : Static_const.t) =
  (* Gc roots: statically allocated blocks themselves do not need to be scanned,
     however if statically allocated blocks contain dynamically allocated
     contents, then that block has to be registered as Gc roots for the Gc to
     correctly patch it if/when it moves some of the dynamically allocated
     blocks. As a safe over-approximation, we thus register as gc_roots all
     symbols who have an associated computation (and thus are not
     fully_static). *)
  let roots =
    if Static_const.is_fully_static static_const then []
    else Symbol.Set.elements (Bound_symbols.being_defined bound_symbols)
  in
  let r = R.add_gc_roots roots R.empty in
  let env, r =
    static_const0 env r ~params_and_body bound_symbols static_const
  in
  (* [R.archive_data] helps keep definitions of separate symbols in different
     [data_item] lists and this increases readability of the generated Cmm. *)
  env, R.archive_data r

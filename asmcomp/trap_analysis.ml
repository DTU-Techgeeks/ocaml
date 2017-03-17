
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

module Int = Numbers.Int

(* The following invariant is relied upon (and checked to a reasonable
   extent): all applications of a given continuation must be at the same
   trap depth.
*)

let rec trap_stacks (insn : Mach.instruction) ~stack ~stacks_at_exit
      : Mach.instruction * (Mach.trap_stack Int.Map.t) =
  let print_stack ppf stack =
    Format.fprintf ppf "%a"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf "; ")
        (fun ppf cont -> Format.fprintf ppf "%d" cont))
      stack
  in
  let add_stack ~cont ~stack ~stacks_at_exit =
    match Int.Map.find cont stacks_at_exit with
    | exception Not_found ->
      Int.Map.add cont stack stacks_at_exit
    | stack' ->
      if stack <> stack' then begin
        Misc.fatal_errorf "Iexit points for continuation %d disagree on \
            the trap stack: existing = %a new = %a"
          cont
          print_stack stack'
          print_stack stack
      end;
      stacks_at_exit
  in
  let register_raise ~stack ~stacks_at_exit =
    match stack with
    | [] -> stacks_at_exit  (* raise to toplevel handler *)
    | cont::_ -> add_stack ~cont ~stack ~stacks_at_exit
  in
  match insn.Mach.desc with
  | Iend ->
    insn, stacks_at_exit
  | Ireturn ->
    begin match stack with
    | [] -> insn, stacks_at_exit
    | _ -> Misc.fatal_error "Trap depth at Ireturn is non-zero"
    end
  | Iop op ->
    let stack, stacks_at_exit =
      match op with
      | Ipushtrap cont ->
        (* CR pchambart: This shouldn't keep the handler alive. If
           there is no raise the handler should be eliminated. *)
        let stacks_at_exit =
          add_stack ~cont ~stack:(cont :: stack) ~stacks_at_exit
        in
        cont :: stack, stacks_at_exit
      | Ipoptrap cont ->
        begin match stack with
        | [] ->
          Misc.fatal_errorf "Tried to poptrap %d but trap stack is empty" cont
        | cont' :: stack ->
          if cont = cont' then
            stack, stacks_at_exit
          else
            Misc.fatal_errorf "Tried to poptrap %d but trap stack has %d \
                at the top"
              cont cont'
        end
      | _ -> stack, stacks_at_exit
    in
    let desc, stacks_at_exit =
      match op with
      | Icall_ind call ->
        let stacks_at_exit = register_raise ~stack ~stacks_at_exit in
        Mach.Iop (Icall_ind ({ call with trap_stack = stack; })),
          stacks_at_exit
      | Icall_imm call ->
        let stacks_at_exit = register_raise ~stack ~stacks_at_exit in
        Mach.Iop (Icall_imm ({ call with trap_stack = stack; })),
          stacks_at_exit
      | Iextcall call ->
        let stacks_at_exit = register_raise ~stack ~stacks_at_exit in
        Mach.Iop (Iextcall ({ call with trap_stack = stack; })),
          stacks_at_exit
      | Iintop (Icheckbound check) ->
        let stacks_at_exit = register_raise ~stack ~stacks_at_exit in
        Mach.Iop (Iintop (Icheckbound ({ check with trap_stack = stack; }))),
          stacks_at_exit
      | Iintop_imm (Icheckbound check, i) ->
        let stacks_at_exit = register_raise ~stack ~stacks_at_exit in
        Mach.Iop (Iintop_imm (
            Icheckbound { check with trap_stack = stack; }, i)),
          stacks_at_exit
      | Ialloc alloc ->
        let stacks_at_exit = register_raise ~stack ~stacks_at_exit in
        Mach.Iop (Ialloc ({ alloc with trap_stack = stack; })),
          stacks_at_exit
      | _ -> Mach.Iop op, stacks_at_exit
    in
    let next, stacks_at_exit =
      trap_stacks insn.Mach.next ~stack ~stacks_at_exit
    in
    { insn with
      desc;
      next; }, stacks_at_exit
  | Iraise (kind, _) ->
    let stacks_at_exit = register_raise ~stack ~stacks_at_exit in
    let next, stacks_at_exit =
      trap_stacks insn.Mach.next ~stack ~stacks_at_exit
    in
    { insn with desc = Iraise (kind, stack); next; }, stacks_at_exit
  | Iunreachable _ ->
    let next, stacks_at_exit =
      trap_stacks insn.Mach.next ~stack ~stacks_at_exit
    in
    { insn with desc = Iunreachable stack; next; }, stacks_at_exit
  | Iifthenelse (cond, ifso, ifnot) ->
    let ifso, stacks_at_exit = trap_stacks ifso ~stack ~stacks_at_exit in
    let ifnot, stacks_at_exit = trap_stacks ifnot ~stack ~stacks_at_exit in
    let next, stacks_at_exit =
      trap_stacks insn.Mach.next ~stack ~stacks_at_exit
    in
    { insn with
      desc = Iifthenelse (cond, ifso, ifnot);
      next;
    }, stacks_at_exit
  | Iswitch (cases, insns) ->
    let stacks_at_exit = ref stacks_at_exit in
    let new_insns = Array.copy insns in
    for case = 0 to Array.length insns - 1 do
      let new_insn, new_stacks_at_exit =
        trap_stacks insns.(case) ~stack ~stacks_at_exit:!stacks_at_exit
      in
      new_insns.(case) <- new_insn;
      stacks_at_exit := new_stacks_at_exit
    done;
    let next, stacks_at_exit =
      trap_stacks insn.Mach.next ~stack ~stacks_at_exit:!stacks_at_exit
    in
    { insn with
      desc = Iswitch (cases, new_insns);
      next;
    }, stacks_at_exit
  | Iloop body ->
    let body, stacks_at_exit = trap_stacks body ~stack ~stacks_at_exit in
    let next, stacks_at_exit =
      trap_stacks insn.Mach.next ~stack ~stacks_at_exit
    in
    { insn with
      desc = Iloop body;
      next;
    }, stacks_at_exit
  | Icatch (rec_flag, is_exn_handler, handlers, body) ->
    assert (not is_exn_handler || List.length handlers = 1);
    let body, stacks_at_exit = trap_stacks body ~stack ~stacks_at_exit in
    let handlers =
      let handlers =
        List.map (fun (cont, _trap_stack, handler) ->
            cont, handler)
          handlers
      in
      Int.Map.of_list handlers
    in
    let handlers_with_uses, handlers_without_uses =
      Int.Map.partition (fun cont _handler ->
          Int.Map.mem cont stacks_at_exit)
        handlers
    in
    let rec process_handlers ~stacks_at_exit ~handlers_with_uses
          ~handlers_without_uses ~output_handlers =
      (* By the invariant above, there is no need to compute a fixpoint. *)
      if Int.Map.is_empty handlers_with_uses then begin
        output_handlers, stacks_at_exit
      end else
        let cont, handler = Int.Map.min_binding handlers_with_uses in
        let handlers_with_uses = Int.Map.remove cont handlers_with_uses in
        match Int.Map.find cont stacks_at_exit with
        | exception Not_found -> assert false
        | stack ->
          (* [handler] is a continuation that is used.  It is called (via
             exit or raise) when the given [stack] of exception handlers are
             in scope. *)
          let stack =
            if not is_exn_handler then
              stack
            else
              match stack with
              | _::stack -> stack
              | [] ->
                Misc.fatal_errorf "Continuation %d is an exception handler \
                    whose trap-stack-at-start is empty"
                  cont
          in
          let handler, stacks_at_exit =
            trap_stacks handler ~stack ~stacks_at_exit
          in
          let new_handlers_with_uses, handlers_without_uses =
            Int.Map.partition (fun cont _handler ->
                Int.Map.mem cont stacks_at_exit)
              handlers_without_uses
          in
          let handlers_with_uses =
            Int.Map.disjoint_union handlers_with_uses new_handlers_with_uses
          in
          process_handlers ~stacks_at_exit ~handlers_with_uses
            ~handlers_without_uses
            ~output_handlers:((cont, stack, handler) :: output_handlers)
    in
    let handlers, stacks_at_exit =
      process_handlers ~stacks_at_exit ~handlers_with_uses
        ~handlers_without_uses ~output_handlers:[]
    in
    let next, stacks_at_exit =
      trap_stacks insn.Mach.next ~stack ~stacks_at_exit
    in
    begin match handlers with
    | [] ->
      { insn with
        desc = Icatch (Nonrecursive, false, [], body);
        next;
      }
    , stacks_at_exit
    | handlers ->
      { insn with
        desc = Icatch (rec_flag, is_exn_handler, handlers, body);
        next;
      }, stacks_at_exit
    end
  | Iexit cont ->
    let stacks_at_exit = add_stack ~cont ~stack ~stacks_at_exit in
    let next, stacks_at_exit =
      trap_stacks insn.Mach.next ~stack ~stacks_at_exit
    in
    { insn with next; }, stacks_at_exit

let run (fundecl : Mach.fundecl) =
  let fun_body, _stacks_at_exit =
    trap_stacks fundecl.fun_body ~stack:[] ~stacks_at_exit:Int.Map.empty
  in
  { fundecl with
    fun_body;
  }

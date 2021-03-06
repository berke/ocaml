(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* Toplevel directives *)

open Format
open Misc
open Longident
open Types
open Cmo_format
open Trace
open Toploop

(* The standard output formatter *)
let std_out = std_formatter

(* To quit *)

let dir_quit () = exit 0

let _ =
  add_directive "quit" "Exit the toplevel loop and terminate the ocaml command."
  (Directive_none dir_quit)

(* To add a directory to the load path *)

let dir_directory s =
  let d = expand_directory Config.standard_library s in
  Config.load_path := d :: !Config.load_path;
  Dll.add_path [d]

let _ = add_directive "directory"
  "Add <string> to search path for source and compiled files."
  (Directive_string dir_directory)

(* To remove a directory from the load path *)
let dir_remove_directory s =
  let d = expand_directory Config.standard_library s in
  Config.load_path := List.filter (fun d' -> d' <> d) !Config.load_path;
  Dll.remove_path [d]

let _ =
  add_directive "remove_directory"
    "Remove <string> from the search path for source and compiled files."
    (Directive_string dir_remove_directory)

(* To change the current directory *)

let dir_cd s = Sys.chdir s

let _ = add_directive "cd" "Change the current working directory"
  (Directive_string dir_cd)

(* Load in-core a .cmo file *)

exception Load_failed

let check_consistency ppf filename cu =
  try
    List.iter
      (fun (name, crco) ->
       Env.add_import name;
       match crco with
         None -> ()
       | Some crc->
           Consistbl.check Env.crc_units name crc filename)
      cu.cu_imports
  with Consistbl.Inconsistency(name, user, auth) ->
    fprintf ppf "@[<hv 0>The files %s@ and %s@ \
                 disagree over interface %s@]@."
            user auth name;
    raise Load_failed

let load_compunit ic filename ppf compunit =
  check_consistency ppf filename compunit;
  seek_in ic compunit.cu_pos;
  let code_size = compunit.cu_codesize + 8 in
  let code = Meta.static_alloc code_size in
  unsafe_really_input ic code 0 compunit.cu_codesize;
  Bytes.unsafe_set code compunit.cu_codesize (Char.chr Opcodes.opRETURN);
  String.unsafe_blit "\000\000\000\001\000\000\000" 0
                     code (compunit.cu_codesize + 1) 7;
  let initial_symtable = Symtable.current_state() in
  Symtable.patch_object code compunit.cu_reloc;
  Symtable.update_global_table();
  let events =
    if compunit.cu_debug = 0 then [| |]
    else begin
      seek_in ic compunit.cu_debug;
      [| input_value ic |]
    end in
  Meta.add_debug_info code code_size events;
  begin try
    may_trace := true;
    ignore((Meta.reify_bytecode code code_size) ());
    may_trace := false;
  with exn ->
    record_backtrace ();
    may_trace := false;
    Symtable.restore_state initial_symtable;
    print_exception_outcome ppf exn;
    raise Load_failed
  end

let rec load_file recursive ppf name =
  let filename =
    try Some (find_in_path !Config.load_path name) with Not_found -> None
  in
  match filename with
  | None -> fprintf ppf "Cannot find file %s.@." name; false
  | Some filename ->
      let ic = open_in_bin filename in
      try
        let success = really_load_file recursive ppf name filename ic in
        close_in ic;
        success
      with exn ->
        close_in ic;
        raise exn

and really_load_file recursive ppf name filename ic =
  let ic = open_in_bin filename in
  let buffer = really_input_string ic (String.length Config.cmo_magic_number) in
  try
    if buffer = Config.cmo_magic_number then begin
      let compunit_pos = input_binary_int ic in  (* Go to descriptor *)
      seek_in ic compunit_pos;
      let cu : compilation_unit = input_value ic in
      if recursive then
        List.iter
          (function
            | (Reloc_getglobal id, _)
              when not (Symtable.is_global_defined id) ->
                let file = Ident.name id ^ ".cmo" in
                begin match try Some (Misc.find_in_path_uncap !Config.load_path
                                        file)
                      with Not_found -> None
                with
                | None -> ()
                | Some file ->
                    if not (load_file recursive ppf file) then raise Load_failed
                end
            | _ -> ()
          )
          cu.cu_reloc;
      load_compunit ic filename ppf cu;
      true
    end else
      if buffer = Config.cma_magic_number then begin
        let toc_pos = input_binary_int ic in  (* Go to table of contents *)
        seek_in ic toc_pos;
        let lib = (input_value ic : library) in
        List.iter
          (fun dllib ->
            let name = Dll.extract_dll_name dllib in
            try Dll.open_dlls Dll.For_execution [name]
            with Failure reason ->
              fprintf ppf
                "Cannot load required shared library %s.@.Reason: %s.@."
                name reason;
              raise Load_failed)
          lib.lib_dllibs;
        List.iter (load_compunit ic filename ppf) lib.lib_units;
        true
      end else begin
        fprintf ppf "File %s is not a bytecode object file.@." name;
        false
      end
  with Load_failed -> false

let dir_load ppf name = ignore (load_file false ppf name)

let _ = add_directive "load" "Load an object (.cmo) or a library (.cma) file"
  (Directive_string (dir_load std_out))

let dir_load_rec ppf name = ignore (load_file true ppf name)

let _ =
  add_directive "load_rec" "Like #load but recursively load missing modules"
  (Directive_string (dir_load_rec std_out))

let load_file = load_file false

(* Load commands from a file *)

let dir_use ppf name = ignore(Toploop.use_file ppf name)
let dir_mod_use ppf name = ignore(Toploop.mod_use_file ppf name)

let _ =
  add_directive "use" "Read and execute source phrases from file <string>"
  (Directive_string (dir_use std_out))

let _ =
  add_directive "mod_use"
    "Like #use, but wraps code in a module named after <string>"
    (Directive_string (dir_mod_use std_out))

(* Install, remove a printer *)

let filter_arrow ty =
  let ty = Ctype.expand_head !toplevel_env ty in
  match ty.desc with
  | Tarrow (lbl, l, r, _) when not (Btype.is_optional lbl) -> Some (l, r)
  | _ -> None

let rec extract_last_arrow desc =
  match filter_arrow desc with
  | None -> raise (Ctype.Unify [])
  | Some (_, r as res) ->
      try extract_last_arrow r
      with Ctype.Unify _ -> res

let extract_target_type ty = fst (extract_last_arrow ty)
let extract_target_parameters ty =
  let ty = extract_target_type ty |> Ctype.expand_head !toplevel_env in
  match ty.desc with
  | Tconstr (path, (_ :: _ as args), _)
      when Ctype.all_distinct_vars !toplevel_env args -> Some (path, args)
  | _ -> None

type 'a printer_type_new = Format.formatter -> 'a -> unit
type 'a printer_type_old = 'a -> unit

let printer_type ppf typename =
  let (printer_type, _) =
    try
      Env.lookup_type (Ldot(Lident "Topdirs", typename)) !toplevel_env
    with Not_found ->
      fprintf ppf "Cannot find type Topdirs.%s.@." typename;
      raise Exit in
  printer_type

let match_simple_printer_type ppf desc printer_type =
  Ctype.begin_def();
  let ty_arg = Ctype.newvar() in
  Ctype.unify !toplevel_env
    (Ctype.newconstr printer_type [ty_arg])
    (Ctype.instance_def desc.val_type);
  Ctype.end_def();
  Ctype.generalize ty_arg;
  (ty_arg, None)

let match_generic_printer_type ppf desc path args printer_type =
  Ctype.begin_def();
  let args = List.map (fun _ -> Ctype.newvar ()) args in
  let ty_target = Ctype.newty (Tconstr (path, args, ref Mnil)) in
  let ty_args =
    List.map (fun ty_var -> Ctype.newconstr printer_type [ty_var]) args in
  let ty_expected =
    List.fold_right
      (fun ty_arg ty -> Ctype.newty (Tarrow (Asttypes.Nolabel, ty_arg, ty,
                                             Cunknown)))
      ty_args (Ctype.newconstr printer_type [ty_target]) in
  Ctype.unify !toplevel_env
    ty_expected
    (Ctype.instance_def desc.val_type);
  Ctype.end_def();
  Ctype.generalize ty_expected;
  if not (Ctype.all_distinct_vars !toplevel_env args) then
    raise (Ctype.Unify []);
  (ty_expected, Some (path, ty_args))

let match_printer_type ppf desc =
  let printer_type_new = printer_type ppf "printer_type_new" in
  let printer_type_old = printer_type ppf "printer_type_old" in
  Ctype.init_def(Ident.current_time());
  try
    (match_simple_printer_type ppf desc printer_type_new, false)
  with Ctype.Unify _ ->
    try
      (match_simple_printer_type ppf desc printer_type_old, true)
    with Ctype.Unify _ as exn ->
      match extract_target_parameters desc.val_type with
      | None -> raise exn
      | Some (path, args) ->
          (match_generic_printer_type ppf desc path args printer_type_new,
           false)

let find_printer_type ppf lid =
  try
    let (path, desc) = Env.lookup_value lid !toplevel_env in
    let (ty_arg, is_old_style) = match_printer_type ppf desc in
    (ty_arg, path, is_old_style)
  with
  | Not_found ->
      fprintf ppf "Unbound value %a.@." Printtyp.longident lid;
      raise Exit
  | Ctype.Unify _ ->
      fprintf ppf "%a has a wrong type for a printing function.@."
      Printtyp.longident lid;
      raise Exit

let dir_install_printer ppf lid =
  try
    let ((ty_arg, ty), path, is_old_style) =
      find_printer_type ppf lid in
    let v = eval_path !toplevel_env path in
    match ty with
    | None ->
       let print_function =
         if is_old_style then
           (fun formatter repr -> Obj.obj v (Obj.obj repr))
         else
           (fun formatter repr -> Obj.obj v formatter (Obj.obj repr)) in
       install_printer path ty_arg print_function
    | Some (ty_path, ty_args) ->
       let rec build v = function
         | [] ->
            let print_function =
              if is_old_style then
                (fun formatter repr -> Obj.obj v (Obj.obj repr))
              else
                (fun formatter repr -> Obj.obj v formatter (Obj.obj repr)) in
            Zero print_function
         | _ :: args ->
            Succ
              (fun fn -> build ((Obj.obj v : _ -> Obj.t) fn) args) in
       install_generic_printer' path ty_path (build v ty_args)
  with Exit -> ()

let dir_remove_printer ppf lid =
  try
    let (ty_arg, path, is_old_style) = find_printer_type ppf lid in
    begin try
      remove_printer path
    with Not_found ->
      fprintf ppf "No printer named %a.@." Printtyp.longident lid
    end
  with Exit -> ()

let _ =
  add_directive "install_printer"
    "Register function <ident> as a printer for its argument type"
    (Directive_ident (dir_install_printer std_out))

let _ = add_directive "remove_printer" "Unregisters a printer"
    (Directive_ident (dir_remove_printer std_out))

(* The trace *)

external current_environment: unit -> Obj.t = "caml_get_current_environment"

let tracing_function_ptr =
  get_code_pointer
    (Obj.repr (fun arg -> Trace.print_trace (current_environment()) arg))

let dir_trace ppf lid =
  try
    let (path, desc) = Env.lookup_value lid !toplevel_env in
    (* Check if this is a primitive *)
    match desc.val_kind with
    | Val_prim p ->
        fprintf ppf "%a is an external function and cannot be traced.@."
        Printtyp.longident lid
    | _ ->
        let clos = eval_path !toplevel_env path in
        (* Nothing to do if it's not a closure *)
        if Obj.is_block clos
        && (Obj.tag clos = Obj.closure_tag || Obj.tag clos = Obj.infix_tag)
        && (match Ctype.(repr (expand_head !toplevel_env desc.val_type))
            with {desc=Tarrow _} -> true | _ -> false)
        then begin
        match is_traced clos with
        | Some opath ->
            fprintf ppf "%a is already traced (under the name %a).@."
            Printtyp.path path
            Printtyp.path opath
        | None ->
            (* Instrument the old closure *)
            traced_functions :=
              { path = path;
                closure = clos;
                actual_code = get_code_pointer clos;
                instrumented_fun =
                  instrument_closure !toplevel_env lid ppf desc.val_type }
              :: !traced_functions;
            (* Redirect the code field of the closure to point
               to the instrumentation function *)
            set_code_pointer clos tracing_function_ptr;
            fprintf ppf "%a is now traced.@." Printtyp.longident lid
        end else fprintf ppf "%a is not a function.@." Printtyp.longident lid
  with
  | Not_found -> fprintf ppf "Unbound value %a.@." Printtyp.longident lid

let dir_untrace ppf lid =
  try
    let (path, desc) = Env.lookup_value lid !toplevel_env in
    let rec remove = function
    | [] ->
        fprintf ppf "%a was not traced.@." Printtyp.longident lid;
        []
    | f :: rem ->
        if Path.same f.path path then begin
          set_code_pointer f.closure f.actual_code;
          fprintf ppf "%a is no longer traced.@." Printtyp.longident lid;
          rem
        end else f :: remove rem in
    traced_functions := remove !traced_functions
  with
  | Not_found -> fprintf ppf "Unbound value %a.@." Printtyp.longident lid

let dir_untrace_all ppf () =
  List.iter
    (fun f ->
      set_code_pointer f.closure f.actual_code;
      fprintf ppf "%a is no longer traced.@." Printtyp.path f.path)
    !traced_functions;
  traced_functions := []

let parse_warnings ppf iserr s =
  try Warnings.parse_options iserr s
  with Arg.Bad err -> fprintf ppf "%s.@." err

(* Typing information *)

let trim_signature = function
    Mty_signature sg ->
      Mty_signature
        (List.map
           (function
               Sig_module (id, md, rs) ->
                 Sig_module (id, {md with md_attributes =
                                    (Location.mknoloc "...", Parsetree.PStr [])
                                    :: md.md_attributes},
                             rs)
             (*| Sig_modtype (id, Modtype_manifest mty) ->
                 Sig_modtype (id, Modtype_manifest (trim_modtype mty))*)
             | item -> item)
           sg)
  | mty -> mty

let dir_help ppf () =
  let directives =
    List.sort
      (fun (key1,_) (key2,_) -> compare key1 key2)
      (Hashtbl.fold (fun key x res -> (key, x) :: res) directive_table [])
  in
  let hdr = ("Directive","Argument(s)","Description") in
  let tmap f (x1,x2,x3) = (f x1, f x2, f x3) in
  let tmap2 f (x1,x2,x3) (y1,y2,y3) = (f x1 y1, f x2 y2, f x3 y3) in
  let res, (n1,n2,n3) =
  List.fold_left
    (fun (res, n_res) (key, (kind, desc)) ->
      let kind_desc =
        match kind with
        | Directive_ident _ -> "<ident>"
        | Directive_none _ -> " "
        | Directive_int _ -> "<int>"
        | Directive_bool _ -> "<bool>"
        | Directive_string _ -> "<string>"
      in
      let r = ("#"^key, kind_desc, desc) in
      let n_res' = tmap2 (fun n u -> max n (String.length u)) n_res r in
      (r :: res, n_res'))
    ([], tmap String.length hdr)
    directives
  in
  let pr (r1,r2,r3) = printf "%-*s | %-*s | %-*s@\n" n1 r1 n2 r2 n3 r3 in
  pr hdr;
  printf "%s@\n" (String.make (n1 + n2 + n3 + 6) '-');
  List.iter pr res;
  fprintf ppf "@."

let show_prim to_sig ppf lid =
  let env = !Toploop.toplevel_env in
  let loc = Location.none in
  try
    let s =
      match lid with
      | Longident.Lident s -> s
      | Longident.Ldot (_,s) -> s
      | Longident.Lapply _ ->
          fprintf ppf "Invalid path %a@." Printtyp.longident lid;
          raise Exit
    in
    let id = Ident.create_persistent s in
    let sg = to_sig env loc id lid in
    Printtyp.wrap_printing_env env
      (fun () -> fprintf ppf "@[%a@]@." Printtyp.signature sg)
  with
  | Not_found ->
      fprintf ppf "@[Unknown element.@]@."
  | Exit -> ()

let all_show_funs = ref []

let reg_show_prim name ~help to_sig =
  all_show_funs := to_sig :: !all_show_funs;
  add_directive "show"
    (Printf.sprintf
      "Describe the %s with this name if it exists in the environment."
      help)
    (Directive_ident (show_prim to_sig std_out))

let () =
  reg_show_prim "show_val" ~help:"value"
    (fun env loc id lid ->
       let path, desc = Typetexp.find_value env loc lid in
       [ Sig_value (id, desc) ]
    )

let () =
  reg_show_prim "show_type" ~help:"type"
    (fun env loc id lid ->
       let path, desc = Typetexp.find_type env loc lid in
       [ Sig_type (id, desc, Trec_not) ]
    )

let () =
  reg_show_prim "show_exception" ~help:"exception"
    (fun env loc id lid ->
       let desc = Typetexp.find_constructor env loc lid in
       if not (Ctype.equal env true [desc.cstr_res] [Predef.type_exn]) then
         raise Not_found;
       let ret_type =
         if desc.cstr_generalized then Some Predef.type_exn
         else None
       in
       let ext =
         { ext_type_path = Predef.path_exn;
           ext_type_params = [];
           ext_args = Cstr_tuple desc.cstr_args;
           ext_ret_type = ret_type;
           ext_private = Asttypes.Public;
           Types.ext_loc = desc.cstr_loc;
           Types.ext_attributes = desc.cstr_attributes; }
       in
         [Sig_typext (id, ext, Text_exception)]
    )

let () =
  reg_show_prim "show_module" ~help:"module"
    (fun env loc id lid ->
       let path, md = Typetexp.find_module env loc lid in
       [ Sig_module (id, {md with md_type = trim_signature md.md_type},
                     Trec_not) ]
    )

let () =
  reg_show_prim "show_module_type" ~help:"module type"
    (fun env loc id lid ->
       let path, desc = Typetexp.find_modtype env loc lid in
       [ Sig_modtype (id, desc) ]
    )

let () =
  reg_show_prim "show_class" ~help:"class"
    (fun env loc id lid ->
       let path, desc = Typetexp.find_class env loc lid in
       [ Sig_class (id, desc, Trec_not) ]
    )

let () =
  reg_show_prim "show_class_type" ~help:"class type"
    (fun env loc id lid ->
       let path, desc = Typetexp.find_class_type env loc lid in
       [ Sig_class_type (id, desc, Trec_not) ]
    )


let show env loc id lid =
  let sg =
    List.fold_left
      (fun sg f -> try (f env loc id lid) @ sg with _ -> sg)
      [] !all_show_funs
  in
  if sg = [] then raise Not_found else sg

let () =
  add_directive "show"
    "Describe this name if it exists in the environment;\
     see also #show_val, #show_type, #show_module etc."
    (Directive_ident (show_prim show std_out))

let _ =
  add_directive "trace" "Trace calls to function <ident>"
    (Directive_ident (dir_trace std_out));
  add_directive "untrace" "Stop tracing function <ident>"
    (Directive_ident (dir_untrace std_out));
  add_directive "untrace_all" "Stop all function traces"
    (Directive_none (dir_untrace_all std_out));

(* Control the printing of values *)

  add_directive "print_depth" "Limit the depth of printed values to <int>"
    (Directive_int(fun n -> max_printer_depth := n));
  add_directive "print_length" "Limit the number of values printed to <int>"
    (Directive_int(fun n -> max_printer_steps := n));

(* Set various compiler flags *)

  add_directive "labels" "Ignore labels in function types (if true)"
             (Directive_bool(fun b -> Clflags.classic := not b));

  add_directive "principal" "Ensure that inferred types are principal (if true)"
             (Directive_bool(fun b -> Clflags.principal := b));

  add_directive "rectypes" "Allow arbitrary recursive types"
             (Directive_none(fun () -> Clflags.recursive_types := true));

  add_directive "ppx" "Pass input phrases through a ppx preprocessor"
    (Directive_string(fun s -> Clflags.all_ppx := s :: !Clflags.all_ppx));

  add_directive "warnings" "Apply the warning filter <string>"
             (Directive_string (parse_warnings std_out false));

  add_directive "warn_error" "Swap listed items between warning and error"
             (Directive_string (parse_warnings std_out true));

  add_directive "help" "This help screen"
     (Directive_none (dir_help std_out));

  ()

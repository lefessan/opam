(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2015 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved.This file is distributed under the terms of the   *)
(*  GNU Lesser General Public License version 3.0 with linking            *)
(*  exception.                                                            *)
(*                                                                        *)
(*  OPAM is distributed in the hope that it will be useful, but WITHOUT   *)
(*  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY    *)
(*  or FITNESS FOR A PARTICULAR PURPOSE.See the GNU General Public        *)
(*  License for more details.                                             *)
(*                                                                        *)
(**************************************************************************)

let log fmt = OpamConsole.log "ACTION" fmt
let slog = OpamConsole.slog

open OpamTypes
open OpamFilename.Op
open OpamState.Types
open OpamProcess.Job.Op

module PackageActionGraph = OpamSolver.ActionGraph

(* Install the package files *)
let process_dot_install t nv =
  if OpamStateConfig.(!r.dryrun) then
    OpamConsole.msg "Installing %s.\n" (OpamPackage.to_string nv)
  else
    let build_dir = OpamPath.Switch.build t.root t.switch nv in
    if OpamFilename.exists_dir build_dir then OpamFilename.in_dir build_dir (fun () ->

      log "Installing %s.\n" (OpamPackage.to_string nv);
      let name = OpamPackage.name nv in
      let config_f = OpamPath.Switch.build_config t.root t.switch nv in
      let config = OpamFile.Dot_config.safe_read config_f in
      let install_f = OpamPath.Switch.build_install t.root t.switch nv in
      let install = OpamFile.Dot_install.safe_read install_f in

      (* .install *)
      let install_f = OpamPath.Switch.install t.root t.switch name in
      OpamFile.Dot_install.write install_f install;

      (* .config *)
      let dot_config = OpamPath.Switch.Default.config t.root t.switch name in
      OpamFilename.mkdir (OpamFilename.dirname dot_config);
      OpamFile.Dot_config.write dot_config config;

      let warnings = ref [] in
      let check ~src ~dst base =
        let src_file = OpamFilename.create src base.c in
        if base.optional && not (OpamFilename.exists src_file) then
          log "Not installing %a is not present and optional."
            (slog OpamFilename.to_string) src_file;
        if not base.optional && not (OpamFilename.exists src_file) then (
          warnings := (dst, base.c) :: !warnings
        );
        OpamFilename.exists src_file in

      (* Install a list of files *)
      let install_files exec dst_fn files_fn =
        let dst_dir = dst_fn t.root t.switch name in
        let files = files_fn install in
        if not (OpamFilename.exists_dir dst_dir) then (
          log "creating %a" (slog OpamFilename.Dir.to_string) dst_dir;
          OpamFilename.mkdir dst_dir;
        );
        List.iter (fun (base, dst) ->
          let src_file = OpamFilename.create build_dir base.c in
          let dst_file = match dst with
            | None   -> OpamFilename.create dst_dir (OpamFilename.basename src_file)
            | Some d -> OpamFilename.create dst_dir d in
          if check ~src:build_dir ~dst:dst_dir base then
            OpamFilename.install ~exec ~src:src_file ~dst:dst_file ();
        ) files in

      let module P = OpamPath.Switch in
      let module I = OpamFile.Dot_install in
      let instdir_gen fpath r s _ = fpath r s t.switch_config in
      let instdir_pkg fpath r s n = fpath r s t.switch_config n in

      (* bin *)
      install_files true (instdir_gen P.bin) I.bin;

      (* sbin *)
      install_files true (instdir_gen P.sbin) I.sbin;

      (* lib *)
      install_files false (instdir_pkg P.lib) I.lib;
      install_files true (instdir_pkg P.lib) I.libexec;

      (* toplevel *)
      install_files false (instdir_gen P.toplevel) I.toplevel;

      install_files true (instdir_gen P.stublibs) I.stublibs;

      (* Man pages *)
      install_files false (instdir_gen P.man_dir) I.man;

      (* Shared files *)
      install_files false (instdir_pkg P.share) I.share;
      install_files false (instdir_gen P.share_dir) I.share_root;

      (* Etc files *)
      install_files false (instdir_pkg P.etc) I.etc;

      (* Documentation files *)
      install_files false (instdir_pkg P.doc) I.doc;

      (* misc *)
      List.iter
        (fun (src, dst) ->
          let src_file = OpamFilename.create (OpamFilename.cwd ()) src.c in
          if OpamFilename.exists dst
            && OpamConsole.confirm "Overwriting %s ?" (OpamFilename.to_string dst) then
            OpamFilename.install ~src:src_file ~dst ()
          else begin
            OpamConsole.msg "Installing %s to %s.\n"
              (OpamFilename.Base.to_string src.c) (OpamFilename.to_string dst);
            if OpamConsole.confirm "Continue ?" then
              OpamFilename.install ~src:src_file ~dst ()
          end
        ) (I.misc install);

      if !warnings <> [] then (
        let print (dir, base) =
          Printf.sprintf "  - %s to %s\n"
            (OpamFilename.to_string (OpamFilename.create build_dir base))
            (OpamFilename.Dir.to_string dir) in
        OpamConsole.error "Installation of %s failed"
          (OpamPackage.to_string nv);
        let msg =
          Printf.sprintf
            "Some files in %s couldn't be installed:\n%s"
            (OpamFilename.prettify install_f)
            (String.concat "" (List.map print !warnings))
        in
        failwith msg
      )
    );
    if not (OpamStateConfig.(!r.keep_build_dir) || (OpamConsole.debug ())) then
      OpamFilename.rmdir build_dir

(* Prepare the package build:
 * apply the patches
 * substitute the files *)
let prepare_package_build t nv =
  let opam = OpamState.opam t nv in

  (* Substitute the patched files.*)
  let patches = OpamFile.OPAM.patches opam in

  let iter_patches f =
    List.fold_left (fun acc (base, filter) ->
      if OpamFilter.opt_eval_to_bool (OpamState.filter_env ~opam t) filter
      then
        try f base; acc with e ->
          OpamStd.Exn.fatal e; OpamFilename.Base.to_string base :: acc
      else acc
    ) [] patches in

  let print_apply basename =
    log "%s: applying %s.\n" (OpamPackage.name_to_string nv)
      (OpamFilename.Base.to_string basename);
    if OpamConsole.verbose () then
      OpamConsole.msg "[%s: patch] applying %s\n"
        (OpamConsole.colorise `green (OpamPackage.name_to_string nv))
        (OpamFilename.Base.to_string basename)
  in

  if OpamStateConfig.(!r.dryrun) || OpamStateConfig.(!r.fake) then
    ignore (iter_patches print_apply)
  else

    let p_build = OpamPath.Switch.build t.root t.switch nv in

    OpamFilename.mkdir p_build;
    OpamFilename.in_dir p_build (fun () ->
      let all = OpamFile.OPAM.substs opam in
      let patches =
        OpamStd.List.filter_map (fun (f,_) ->
          if List.mem f all then Some f else None
        ) patches in
      List.iter
        (OpamFilter.expand_interpolations_in_file (OpamState.filter_env ~opam t))
        patches
    );

  (* Apply the patches *)
    let patching_errors =
      iter_patches (fun base ->
        let root = OpamPath.Switch.build t.root t.switch nv in
        let patch = root // OpamFilename.Base.to_string base in
        print_apply base;
        OpamFilename.patch patch p_build)
    in

  (* Substitute the configuration files. We should be in the right
     directory to get the correct absolute path for the
     substitution files (see [substitute_file] and
     [OpamFilename.of_basename]. *)
    OpamFilename.in_dir p_build (fun () ->
      List.iter
        (OpamFilter.expand_interpolations_in_file (OpamState.filter_env ~opam t))
        (OpamFile.OPAM.substs opam)
    );
    if patching_errors <> [] then (
      let msg =
        Printf.sprintf "These patches didn't apply at %s:\n%s"
          (OpamFilename.Dir.to_string (OpamPath.Switch.build t.root t.switch nv))
          (OpamStd.Format.itemize (fun x -> x) patching_errors)
      in
      failwith msg
    )

let download_package t nv =
  log "download_package: %a" (slog OpamPackage.to_string) nv;
  let name = OpamPackage.name nv in
  if OpamStateConfig.(!r.dryrun) || OpamStateConfig.(!r.fake) then Done (`Successful None) else
    let dir =
      try match OpamPackage.Name.Map.find name t.pinned with
      | Version _ -> Some (OpamPath.dev_package t.root nv)
      | _ -> Some (OpamPath.Switch.dev_package t.root t.switch name)
      with Not_found -> None
    in
    let of_dl = function
      | Some (Up_to_date f | Result f) -> `Successful (Some f)
      | Some (Not_available s) -> `Error s
      | None -> `Successful None
    in
    let job = match dir with
      | Some dir ->
        OpamState.download_upstream t nv dir @@| of_dl
      | None ->
        OpamState.download_archive t nv @@+ function
        | Some f ->
          assert (f = OpamPath.archive t.root nv);
          Done (`Successful (Some (F f)))
        | None ->
          let dir = OpamPath.dev_package t.root nv in
          OpamState.download_upstream t nv dir @@| of_dl
    in
  (* let extras = *)
  (*   List.map (fun (url,checksum,fname) -> *)
  (*       OpamDownload.download_as ~checksum  *)
    OpamProcess.Job.catch (fun e -> Done (`Error (Printexc.to_string e))) job

let extract_package t source nv =
  log "extract_package: %a from %a"
    (slog OpamPackage.to_string) nv
    (slog (OpamStd.Option.to_string OpamTypesBase.string_of_generic_file))
    source;
  if OpamStateConfig.(!r.dryrun) then () else
    let build_dir = OpamPath.Switch.build t.root t.switch nv in
    OpamFilename.rmdir build_dir;
    let () =
      match source with
      | None -> ()
      | Some (D dir) -> OpamFilename.copy_dir ~src:dir ~dst:build_dir
      | Some (F archive) -> OpamFilename.extract archive build_dir
    in
    let is_repackaged_archive =
      Some (F (OpamPath.archive t.root nv)) = source
    in
    if not is_repackaged_archive then OpamState.copy_files t nv build_dir;
    prepare_package_build t nv

(* unused ?
   let string_of_commands commands =
   let commands_s = List.map (fun cmd -> String.concat " " cmd)  commands in
   "  "
   ^ if commands_s <> [] then
   String.concat "\n  " commands_s
   else
   "Nothing to do."
*)

let compilation_env t opam =
  let env0 = OpamState.get_full_env ~force_path:true t in
  let env1 = [
    ("MAKEFLAGS", "", None);
    ("MAKELEVEL", "", None);
    ("OPAM_PACKAGE_NAME",
     OpamPackage.Name.to_string (OpamFile.OPAM.name opam),
     None);
    ("OPAM_PACKAGE_VERSION",
     OpamPackage.Version.to_string (OpamFile.OPAM.version opam),
     None)
  ] @ env0 in
  OpamState.add_to_env t env1 (OpamFile.OPAM.build_env opam)

let update_switch_state ?installed ?installed_roots ?reinstall ?pinned t =
  let open OpamStd.Option.Op in
  let open OpamPackage.Set.Op in
  let installed = installed +! t.installed in
  let compiler_packages =
    if OpamPackage.Set.is_empty (t.compiler_packages -- installed) then
      t.compiler_packages
    else (* adjust version of installed compiler packages *)
      let names = OpamPackage.names_of_packages t.compiler_packages in
      let installed_base = OpamPackage.packages_of_names installed names in
      installed_base ++
      (* keep version of uninstalled compiler packages *)
        OpamPackage.packages_of_names t.compiler_packages
        (OpamPackage.Name.Set.diff names
           (OpamPackage.names_of_packages installed_base))
  in
  let t =
    { t with
      installed;
      installed_roots = (installed_roots +! t.installed_roots) %% installed;
      reinstall = (reinstall +! t.reinstall) %% installed;
      pinned = pinned +! t.pinned;
      compiler_packages; }
  in
  if not OpamStateConfig.(!r.dryrun) then (
    OpamState.write_switch_state t;
    OpamFile.PkgList.write
      (OpamPath.Switch.reinstall t.root t.switch)
      t.reinstall
  );
  t

let removal_needs_download t nv =
  match OpamState.opam_opt t nv with
  | None ->
    OpamConsole.warning
      "No opam file found to remove package %s. Stale files may remain."
      (OpamPackage.to_string nv);
    false
  | Some opam ->
    if OpamFile.OPAM.has_flag Pkgflag_LightUninstall opam then true
    else
      let commands =
        OpamFilter.commands (OpamState.filter_env ~opam t)
          (OpamFile.OPAM.remove opam) in
    (* We use a small hack: if the remove command is simply
       'ocamlfind remove xxx' then, no need to extract the archive
       again. *)
      let use_ocamlfind = function
        | [] -> true
        | "ocamlfind" :: _ -> true
        | _ -> false in
      not (List.for_all use_ocamlfind commands)

(* Remove a given package *)
let remove_package_aux t ?(keep_build=false) ?(silent=false) nv =
  log "Removing %a" (slog OpamPackage.to_string) nv;
  let name = OpamPackage.name nv in

  (* Run the remove script *)
  let opam = OpamState.opam_opt t nv in

  let dot_install = OpamPath.Switch.install t.root t.switch name in

  let remove_job =
    match opam with
    | None      -> OpamConsole.msg "No OPAM file has been found!\n"; Done ()
    | Some opam ->
      let env = compilation_env t opam in
      let p_build = OpamPath.Switch.build t.root t.switch nv in
      (* We try to run the remove scripts in the folder where it was
         extracted If it does not exist, we try to download and
         extract the archive again, if that fails, we don't really
         care. *)
      let remove =
        OpamFilter.commands (OpamState.filter_env ~opam t)
          (OpamFile.OPAM.remove opam) in
      let name = OpamPackage.Name.to_string name in
      let exec_dir, nameopt =
        if OpamFilename.exists_dir p_build
        then p_build, Some name
        else t.root , None in
      (* if remove <> [] || not (OpamFilename.exists dot_install) then *)
      (*   OpamConsole.msg "%s\n" (string_of_commands remove); *)
      let commands =
        OpamStd.List.filter_map (function
        | [] -> None
        | cmd::args ->
          let text = OpamProcess.make_command_text name ~args cmd in
          Some
            (OpamSystem.make_command ?name:nameopt ~text cmd args
               ~env:(OpamTypesBase.env_array env)
               ~dir:(OpamFilename.Dir.to_string exec_dir)
               ~verbose:(OpamConsole.verbose ())
               ~check_existence:false))
          remove
      in
      OpamProcess.Job.of_list ~keep_going:true commands
      @@+ function
      | Some (_,err) ->
        if not silent then
          OpamConsole.warning
            "failure in package uninstall script, some files may remain:\n%s"
            (OpamProcess.string_of_result err);
        Done ()
      | None -> Done ()
  in

  let install =
    OpamFile.Dot_install.safe_read dot_install in

  let remove_files dst_fn files =
    let files = files install in
    let dst_dir = dst_fn t.root t.switch t.switch_config in
    List.iter (fun (base, dst) ->
      let dst_file = match dst with
        | None   -> dst_dir // Filename.basename (OpamFilename.Base.to_string base.c)
        | Some b -> OpamFilename.create dst_dir b in
      OpamFilename.remove dst_file
    ) files in

  let remove_files_and_dir ?(quiet=false) dst_fn files =
    let dir = dst_fn t.root t.switch t.switch_config name in
    remove_files (fun _ _ _ -> dir) files;
    if OpamFilename.rec_files dir = [] then OpamFilename.rmdir dir
    else if not quiet && OpamFilename.exists_dir dir then
      OpamConsole.warning "Directory %s is not empty, not removing"
        (OpamFilename.Dir.to_string dir) in

  let uninstall_files () =
    (* Remove build/<package> *)
    if not (keep_build || OpamStateConfig.(!r.keep_build_dir)) then
      OpamFilename.rmdir (OpamPath.Switch.build t.root t.switch nv);

    (* Remove .config and .install *)
    log "Removing config and install files";
    OpamFilename.remove (OpamPath.Switch.install t.root t.switch name);
    OpamFilename.remove
      (OpamPath.Switch.config t.root t.switch t.switch_config name);

    log "Removing files from .install";
    remove_files OpamPath.Switch.sbin OpamFile.Dot_install.sbin;
    remove_files OpamPath.Switch.bin OpamFile.Dot_install.bin;
    remove_files_and_dir ~quiet:true
      OpamPath.Switch.lib OpamFile.Dot_install.libexec;
    remove_files_and_dir OpamPath.Switch.lib OpamFile.Dot_install.lib;
    remove_files OpamPath.Switch.stublibs OpamFile.Dot_install.stublibs;
    remove_files_and_dir OpamPath.Switch.share OpamFile.Dot_install.share;
    remove_files OpamPath.Switch.share_dir OpamFile.Dot_install.share_root;
    remove_files_and_dir OpamPath.Switch.etc OpamFile.Dot_install.etc;
    remove_files (OpamPath.Switch.man_dir ?num:None) OpamFile.Dot_install.man;
    remove_files_and_dir OpamPath.Switch.doc OpamFile.Dot_install.doc;

    (* Remove the misc files *)
    log "Removing the misc files";
    List.iter (fun (_,dst) ->
      if OpamFilename.exists dst then begin
        OpamConsole.msg "Removing %s." (OpamFilename.to_string dst);
        if OpamConsole.confirm "Continue ?" then
          OpamFilename.remove dst
      end
    ) (OpamFile.Dot_install.misc install);

    (* Cleanup if there was any stale overlay (unpinned but left installed
       package) *)
    if not (OpamState.is_pinned t name) then
      OpamState.remove_overlay t name;
  in

  remove_job @@+ fun () ->
    if not OpamStateConfig.(!r.dryrun) then uninstall_files ();
    if not silent then
      OpamConsole.msg "%s removed   %s.%s\n"
        (if not (OpamConsole.utf8 ()) then "->" else
            OpamActionGraph.(action_color (`Remove ())
                               (action_strings (`Remove ()))))
        (OpamConsole.colorise `bold (OpamPackage.name_to_string nv))
        (OpamPackage.version_to_string nv);
    Done ()


(* Removes build dir and source cache of package if unneeded *)
let cleanup_package_artefacts t nv =
  log "Cleaning up artefacts of %a" (slog OpamPackage.to_string) nv;

  let build_dir = OpamPath.Switch.build t.root t.switch nv in
  if not OpamStateConfig.(!r.keep_build_dir) && OpamFilename.exists_dir build_dir then
    OpamFilename.rmdir build_dir;
  let name = OpamPackage.name nv in
  let dev_dir = OpamPath.Switch.dev_package t.root t.switch name in
  if not (OpamState.is_package_installed t nv) then (
    if OpamFilename.exists_dir dev_dir then (
      log "Cleaning-up the switch repository";
      OpamFilename.rmdir dev_dir );
    log "Removing the local metadata";
    OpamState.remove_metadata t (OpamPackage.Set.singleton nv);
  );

  (* Remove the dev archive if no switch uses the package anymore *)
  let dev = OpamPath.dev_package t.root nv in
  if OpamFilename.exists_dir dev &&
    not (OpamPackage.Set.mem nv (OpamState.all_installed t)) then (
      log "Removing %a" (slog OpamFilename.Dir.to_string) dev;
      OpamFilename.rmdir dev;
    )

let sources_needed t g =
  PackageActionGraph.fold_vertex (fun act acc ->
    match act with
    | `Remove nv ->
      if removal_needs_download t nv
      then OpamPackage.Set.add nv acc else acc
    | `Install nv -> OpamPackage.Set.add nv acc
    | _ -> assert false)
    g OpamPackage.Set.empty

let remove_package t ?keep_build ?silent nv =
  if OpamStateConfig.(!r.fake) || OpamStateConfig.(!r.show) then
    Done (OpamConsole.msg "Would remove: %s.\n" (OpamPackage.to_string nv))
  else
    remove_package_aux t ?keep_build ?silent nv




(***********************************************************************)
(***********************************************************************)
(***********************************************************************)
(***********************************************************************)
(***********************************************************************)
(***********************************************************************)
(***********************************************************************)




let add_depends_from_formulas t depends deps =
  OpamFormula.fold_left (fun accu (n,_) ->
    if OpamState.is_name_installed t n then
      let nv = OpamState.find_installed_package_by_name t n in
      OpamPackage.to_string nv :: accu
    else
      accu
  ) depends deps

let package_variables t nv =
  match OpamState.opam_opt t nv with
  | None ->
    OpamConsole.warning
      "No opam file found for package %s. Cannot install."
      (OpamPackage.to_string nv);
    exit 2
  | Some opam ->

  (* Computing all this is useless in most cases. We should probably add
     a | LS of string Lazy.t to OpamTypes.variable_contents to compute
     them only when useful. *)
    let depends = add_depends_from_formulas t []
      (OpamFile.OPAM.depends opam) in
    let depopts = add_depends_from_formulas t []
      (OpamFile.OPAM.depopts opam) in
    OpamConsole.warning
      "Package %s: current depends are %s and depopts are %s."
      (OpamPackage.to_string nv)
      (String.concat "," depends)
      (String.concat "," depopts)
    ;
    (depends, depopts)

let opam_build = try Some  (Sys.getenv "OPAM_BUILD") with _ -> None
let be_verbose = opam_build <> None

let verbose_result result =
  if be_verbose then begin
    List.iter (Printf.printf "%s\n") result.OpamProcess.r_stdout;
    List.iter (Printf.eprintf "%s\n") result.OpamProcess.r_stderr;
  end;
  ()

let cut_at s c =
  let pos = String.index s c in
  String.sub s 0 pos, String.sub s (pos+1) (String.length s - pos - 1)

let digest_package t nv builder_dir =
  let (depends, depopts) = package_variables t nv in
  let cache_dir = Filename.concat builder_dir "cache" in
  let versions =
    OpamPackage.to_string nv :: depopts @ depends
  in
  let versions = List.sort compare versions in
  let b = Buffer.create 10000 in
  Buffer.add_string b (OpamSwitch.to_string t.switch);
  List.iter (fun version_name ->
    let package_name, _ = cut_at version_name '.' in
    let package_dir = Filename.concat cache_dir package_name in
    let version_dir = Filename.concat package_dir version_name in
    let checksum_file = Filename.concat version_dir "checksum.txt" in
    let ic = open_in checksum_file in
    let checksum = input_line ic in
    close_in ic;
    Buffer.add_string b version_name;
    Buffer.add_string b checksum;
  ) versions;
  Digest.string (Buffer.contents b)

module StringSet = Set.Make(String)


module Snapshot : sig

  type t = {
    files : (string * kind) list;
  }
  and kind =
  | File of file
  | Dir of t
  | Link of string
  and file = {
    file_size : int;
    file_mtime : float;
  }

  val make : string -> (* ignored_files *) StringSet.t -> t
  val save : string -> t -> unit
  val load : string -> t
  val diff : (* after *) t -> (* before *) t -> t

  val copy_files : (* src_dir *) string -> t -> (* dst_dir *) string -> unit
  val remove_files : string -> t -> unit

end  = struct

  type t = {
    files : (string * kind) list;
  }
  and kind =
  | File of file
  | Dir of t
  | Link of string
  and file = {
    file_size : int;
    file_mtime : float;
  }

  let rec make dir base ignored =
    let files = Sys.readdir dir in Array.sort compare files;
    let snapshot_files = ref [] in
    Array.iter (fun file ->
      if not (StringSet.mem (Filename.concat base file) ignored) then
        let kind =
          let filename = Filename.concat dir file in
          let st = Unix.lstat filename in
          match st.Unix.st_kind with
          | Unix.S_REG ->
            File {
              file_size = st.Unix.st_size;
              file_mtime = st.Unix.st_mtime;
            }
          | Unix.S_DIR ->
            Dir (make filename (Filename.concat base file) ignored)
          | Unix.S_LNK ->
            let link = Unix.readlink filename in
            Link link
          | _ -> assert false (* TODO: better message *)
        in
        snapshot_files := (file, kind) :: !snapshot_files
    ) files;
    { files = List.rev !snapshot_files }

  let make dir ignored = make dir "." ignored

  let save filename t =
    let oc = open_out filename in
    let rec save t =
      List.iter (fun (file, kind) ->
        match kind with
        | Link link ->
          Printf.fprintf oc "LINK\n%s\n" file;
          Printf.fprintf oc "%s\n" link;
        | Dir t ->
          Printf.fprintf oc "DIR\n%s\n" file;
          save t;
        | File f ->
          Printf.fprintf oc "FILE\n%s\n" file;
          Printf.fprintf oc "%d\n" f.file_size;
          Printf.fprintf oc "%f\n" f.file_mtime;
      ) t.files;
      Printf.fprintf oc "END\n";
    in
    save t;
    close_out oc

  let lines_of_file filename =
    let ic = open_in filename in
    let lines = ref [] in
    try
      while true do
        lines := (input_line ic) :: !lines
      done;
      assert false
    with _ ->
      close_in ic;
      List.rev !lines

  let load filename =
    let lines = lines_of_file filename in
    let rec load lines files =
      match lines with
      | "END" :: rem ->
        { files = List.rev files }, rem
      | "LINK" :: file :: link :: rem ->
        load rem ( (file, Link link) :: files )
      | "DIR" :: file :: rem ->
        let t, rem = load rem [] in
        load rem ( (file, Dir t) :: files )
      | "FILE" :: file :: file_size :: file_mtime :: rem ->
        let f = {
          file_size = int_of_string file_size;
          file_mtime = float_of_string file_mtime;
        } in
        load rem ( (file, File f) :: files )
      | _ -> assert false
    in
    let t,rem = load lines [] in
    assert (rem = []);
    t

  (* For now, we only support adding files, not removing them ! *)
  let diff after before = (* TODO *)
    let rec diff_files after before files =
      match after, before with
      | _, [] -> List.rev files @ after
      | [], _ :: _ -> assert false (* TODO : better error message *)
      | (file1, kind1) :: after1,
        (file2, kind2) :: before2 ->
        if file1 < file2 then
          diff_files after1 before ( (file1, kind1) :: files )
        else
          if file1 = file2 then
            let files =
              match kind1, kind2 with
              | File f1, File f2 ->
                if f1 <> f2 then (file1, kind1) :: files
                else files
              | Dir { files = files1 }, Dir { files = files2 } ->
                let diff = diff_files files1 files2 [] in
                if diff <> [] then
                  (file1, Dir { files = diff } ) :: files
                else files

              | Link link1, Link link2 ->
              (* TODO: check that tar can change links *)
                if link1 <> link2 then (file1, kind1) :: files
                else files

              | _ -> assert false (* TODO: better error message *)
            in
            diff_files after1 before2 files
          else
            assert false (* file1 > file2 : TODO : better error message *)
    in
    { files = diff_files after.files before.files [] }

  let rec copy_files prefix snap destdir =
    List.iter (fun (file, kind) ->
      let src_file = Filename.concat prefix file in
      let dst_file = Filename.concat destdir file in
      match kind with
      | Link link ->
        if Filename.is_relative link then
          Unix.symlink link dst_file
        else assert false
      | Dir snap ->
        Unix.mkdir dst_file 0o755; (* TODO: add perms in snapshots *)
        copy_files src_file snap dst_file
      | File _ ->
        let exit =  (* call cp for now, because it keeps perms *)
          Printf.kprintf Sys.command "cp '%s' '%s'" src_file dst_file
        in
        assert (exit = 0);
    (*
      let s = File.string_of_file src_file in
      File.file_of_string dst_file s  (* TODO: add perms in snapshots *)
    *)
    ) snap.files

  let rec remove_files prefix snap =
    List.iter (fun (file, kind) ->
      let src_file = Filename.concat prefix file in
      match kind with
      | Link _
      | File _ ->
        Sys.remove src_file
      | Dir snap ->
        remove_files src_file snap;
        (try Unix.rmdir src_file with _ -> ())
    ) snap.files

end


  (* TODO: we should have an option for every system. Ideally,
     opam should not build in the same directory as prefix ! *)
let opam_ignored_files =
  let set = ref StringSet.empty in
  List.iter (fun file ->
    set := StringSet.add file !set
  ) [
    "./backup"; "./build"; "./config";
    "./install"; "./overlay"; "./packages.dev";
    "./installed"; "./installed_roots"; "./state"; "./environment";
    "./reinstall"; "./pinned";
  ];
  !set

let snapshot_opam_switch switch_dir =
  Snapshot.make switch_dir opam_ignored_files

type action_kind =
  BuildAction | InstallAction

let cache_package_action kind t nv create_job =
  match opam_build with
  | None -> create_job t nv
  | Some builder_dir ->
    let package_hash = digest_package t nv builder_dir in
    let cache_dir = Filename.concat builder_dir "cache" in
    let version_name = OpamPackage.to_string nv in
    let package_name, _ = cut_at version_name '.' in
    let package_dir = Filename.concat cache_dir package_name in
    let version_dir = Filename.concat package_dir version_name in
    let archive_file_prefix =
      Filename.concat version_dir
        (Printf.sprintf "%s-%s"
           (Digest.to_hex package_hash)
           (OpamSwitch.to_string t.switch))
    in
    let build_archive_file =
      Printf.sprintf "%s-%s.tar.gz" archive_file_prefix "build" in
    let install_archive_file =
      Printf.sprintf "%s-%s.tar.gz" archive_file_prefix "build" in
    let archive_file =
      match kind with
      | BuildAction -> build_archive_file
      | InstallAction -> install_archive_file
    in
    let switch_dir = OpamPath.Switch.root t.root t.switch in
    let switch_dir = OpamFilename.Dir.to_string switch_dir in
    if not (Sys.file_exists archive_file) then begin
      begin match kind with
      | InstallAction -> ()
      | BuildAction ->
        ignore (Printf.kprintf Sys.command "rm -f %s" install_archive_file)
      end;
      Printf.eprintf "Snapshotting %s...\n%!" switch_dir;
      let sn_before = Snapshot.make switch_dir opam_ignored_files in
      Printf.eprintf "Snapshotting %s...done\n%!" switch_dir;
      create_job t nv @@+ (fun result ->
        match result with
        | Some exn ->
              (* Something wrong happened,
                 use the snapshot to clean everything. *)
          Printf.eprintf
            "Build failed. Snapshot found. Using it to clean files...\n%!";
          Snapshot.remove_files switch_dir sn_before;
          Done (Some exn)

        | None ->

          try
            Printf.eprintf "Snapshotting %s...\n%!" switch_dir;
            let sn_after = Snapshot.make switch_dir opam_ignored_files in
            Printf.eprintf "Snapshotting %s...done\n%!" switch_dir;
              (* compare snapshot if necessary *)
            let sn_diff = Snapshot.diff sn_after sn_before in
              (* build archive with result, and save *)

              (* Build archive *)
            Printf.eprintf "Building archive...\n%!";
            let destdir = "_destdir" in
            ignore (Printf.kprintf Sys.command "rm -rf %s" destdir);
            (try Sys.remove destdir with _ -> ());
            Unix.mkdir destdir 0o755;
            Printf.eprintf "Copying installed files...\n%!";
            Snapshot.copy_files switch_dir sn_diff destdir;
            Snapshot.save (archive_file ^ ".snap") sn_diff;
            Printf.eprintf "Copying installed files...done\n%!";
            Unix.chdir destdir;
            let exit = Printf.kprintf Sys.command "tar zcf %s ." archive_file in
            assert (exit = 0);
            Unix.chdir "..";
            ignore (Printf.kprintf Sys.command "rm -rf %s" destdir);
            Printf.eprintf "Archive %s done\n\n\n%!" archive_file;

            Done None
          with exn -> Done (Some exn)
      )
    end else begin
      let current_dir = Sys.getcwd () in
      Unix.chdir switch_dir;
      Printf.eprintf "Extracting archive %s\n%!" archive_file;
      let exitcode = Printf.kprintf Sys.command "tar zxf %s" archive_file in
      Unix.chdir current_dir;
      if exitcode <> 0 then begin
        Printf.eprintf "Error while extracting archive content in %s\n%!"
          switch_dir;
        exit 2
      end;
      Done None
    end

(***********************************************************************)
(***********************************************************************)
(***********************************************************************)
(***********************************************************************)
(***********************************************************************)
(***********************************************************************)
(***********************************************************************)




(* Compiles a package.
   Assumes the package has already been downloaded to [source].
*)
let build_package t source nv =
  Printf.eprintf "\n\n\nbuild_package %s\n\n\n%!" (OpamPackage.to_string nv);

  cache_package_action BuildAction t nv (fun t nv ->
    extract_package t source nv;
    let opam = OpamState.opam t nv in
    let commands =
      OpamFile.OPAM.build opam @
        (if OpamStateConfig.(!r.build_test)
           then OpamFile.OPAM.build_test opam else []) @
          (if OpamStateConfig.(!r.build_doc)
           then OpamFile.OPAM.build_doc opam else [])
      in
      let commands = OpamFilter.commands (OpamState.filter_env ~opam t) commands in
      let env = OpamTypesBase.env_array (compilation_env t opam) in
      let name = OpamPackage.name_to_string nv in
      let dir = OpamPath.Switch.build t.root t.switch nv in
      let rec run_commands = function
        | (cmd::args)::commands ->
          let text = OpamProcess.make_command_text name ~args cmd in
          let dir = OpamFilename.Dir.to_string dir in
          OpamSystem.make_command ~env ~name ~dir ~text
            ~verbose:(OpamConsole.verbose ()) ~check_existence:false
            cmd args
          @@> fun result ->
            verbose_result result;
            if OpamProcess.is_success result then
              run_commands commands
            else
              (OpamConsole.error
                 "The compilation of %s failed at %S."
                 name (String.concat " " (cmd::args));
             (* FIXME: this shouldn't be needed, but lots of packages still install
                during this step, so make sure to cleanup *)
               remove_package t ~keep_build:true ~silent:true nv @@+ fun () ->
                 Done (Some (OpamSystem.Process_error result)))
        | []::commands -> run_commands commands
        | [] -> Done None
      in
      run_commands commands
  )

(* Assumes the package has already been compiled in its build dir.
   Does not register the installation in the metadata ! *)
let install_package t nv =
  Printf.eprintf "\n\n\ninstall_package %s\n\n\n%!" (OpamPackage.to_string nv);

  cache_package_action InstallAction t nv (fun t nv ->
      let opam = OpamState.opam t nv in
      let commands = OpamFile.OPAM.install opam in
      let commands = OpamFilter.commands (OpamState.filter_env ~opam t) commands in
      let env = OpamTypesBase.env_array (compilation_env t opam) in
      let name = OpamPackage.name_to_string nv in
      let dir = OpamPath.Switch.build t.root t.switch nv in
      let rec run_commands = function
        | (cmd::args)::commands ->
          let text = OpamProcess.make_command_text name ~args cmd in
          let dir = OpamFilename.Dir.to_string dir in
          OpamSystem.make_command ~env ~name ~dir ~text
            ~verbose:(OpamConsole.verbose ()) ~check_existence:false
            cmd args
          @@> fun result ->
            verbose_result result;
            if OpamFile.OPAM.has_flag Pkgflag_Verbose opam then
              List.iter (OpamConsole.msg "%s\n") result.OpamProcess.r_stdout;
            if OpamProcess.is_success result then
              run_commands commands
            else (
              OpamConsole.error
                "The installation of %s failed at %S."
                name (String.concat " " (cmd::args));
              remove_package t ~keep_build:true ~silent:true nv
              @@| fun () -> Some (OpamSystem.Process_error result)
            )
        | []::commands -> run_commands commands
        | [] -> Done None
      in
      run_commands commands @@+ function
      | Some _ as err -> Done err
      | None ->
        try
          process_dot_install t nv;
          Done None
        with e ->
          remove_package t ~keep_build:true ~silent:true nv
          @@| fun () -> OpamStd.Exn.fatal e; Some e
  ) @@+ function
  | None ->
    let name = OpamPackage.name_to_string nv in
    OpamConsole.msg "%s installed %s.%s\n"
      (if not (OpamConsole.utf8 ()) then "->"
       else OpamActionGraph.
          (action_color (`Install ()) (action_strings (`Install ()))))
      (OpamConsole.colorise `bold name)
      (OpamPackage.version_to_string nv);
    Done None
  | Some exn -> Done (Some exn)

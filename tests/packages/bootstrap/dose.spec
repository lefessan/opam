@1

package "dose" {
  version     = "3bc571a6e029c413004b5f0402366a85b73019a8"
  description = "git://scm.gforge.inria.fr/mancoosi-tools/dose.git"
  patches = [ "https://transfert.inria.fr/fichiers/fb7dc4e64b23a1ed1e49e3a1f17f49a7/dose.tar.bz2"
            ; "local://dose.install"
            ; "local://dose.ocp.boot" ]
  make = [ # Sys.command (Printf.sprintf "for i in ocamlre extlib cudf ocamlgraph ocpgetboot ; do echo 'begin library \"'$i'\" dirname = \"'$(ocp-get %s config -I $i | cut -d ' ' -f 2)'\" end' >> dose.ocp ; done" (match try Some (Unix.getenv "OPAM_ROOT") with Not_found -> None with None -> "" | Some s -> "--root " ^ s)) #
         ; # Sys.command "cat dose.ocp.boot >> dose.ocp" #
         ; # let exec s a = Unix.execvp s (Array.append [|s|] a) in exec "ocp-build" [| "-init" ; "-scan" |] # ]
  depends = [ [ ["ocamlre"] ] ; [ ["extlib"] ] ; [ ["cudf"] ] ; [ ["ocamlgraph"] ] ; [ ["ocpgetboot"] ] ]
}

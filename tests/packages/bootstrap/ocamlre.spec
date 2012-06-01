@1

package "ocamlre" {
  version     = "191229137d8268e1847e13fbf3bd6522ab062a21"
  description = "https://github.com/avsm/ocaml-re.git"
  patches = [ "https://transfert.inria.fr/fichiers/1ddcb82a1ba337fe32aabfaf4621d3e5/ocaml-re.tar.bz2"
            ; "local://ocamlre.install"
            ; [ "local://ocamlre.ocp.boot" ; "ocamlre.ocp" ] ]
  make = [ # let exec s a = Unix.execvp s (Array.append [|s|] a) in exec "ocp-build" [| "-init" ; "-scan" |] # ]
}

@1

package "P4" {
  version     = "3"
  description = "Testing transitive closure"
  sources     = [ "https://transfert.inria.fr/fichiers/dd17f5e213368e4bf6be1c3e888bd29c/p4.tar.gz" ]
  patches     = [ "https://transfert.inria.fr/fichiers/760b0fc6e6a11907189726d122b352fa/p4.diff"
                ; "file://P4-3_build.sh" ]
  make        = [ # Sys.command "./P4-3_build.sh" # ]
  depends     = [ [ ["P2"] ] ; [ ["P3"] ] ]
}

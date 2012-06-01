@1

package "P4" {
  version     = "2"
  description = "Testing constraints"
  patches     = [ "https://transfert.inria.fr/fichiers/dd17f5e213368e4bf6be1c3e888bd29c/p4.tar.gz"
                ; [ "file://P4-3_build.sh" ; "./P4-2_build.sh" ] ]
  make        = [ # Sys.command "./P4-2_build.sh" # ]
  depends     = [ [ ["P1";"=";"1"] ]
                ; [ ["P2"] ]
                ; [ ["P3"] ] ]
}

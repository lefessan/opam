OS = $(shell uname -s)
ifeq ($(OS),Darwin)
WGET ?= ftp
else
WGET ?= wget -qN --no-check-certificate
endif

all: clone

clone: cudf extlib ocaml-re ocamlgraph dose ocaml-arg

cudf:
	$(WGET) https://transfert.inria.fr/fichiers/1a7a183bdfde274d15030004cb9eae3a/cudf.tar.bz2
	tar xfj cudf.tar.bz2

extlib:
	$(WGET) http://ocaml-extlib.googlecode.com/files/extlib-1.5.2.tar.gz
	tar xfz extlib-1.5.2.tar.gz
	mv extlib-1.5.2 extlib

dose:
	$(WGET) https://transfert.inria.fr/fichiers/fb7dc4e64b23a1ed1e49e3a1f17f49a7/dose.tar.bz2
	tar xfj dose.tar.bz2

ocaml-arg:
	$(WGET) https://transfert.inria.fr/fichiers/8b023ee317f4b46daedadc6fee0d930e/ocaml-arg.tar.bz2
	tar xfj ocaml-arg.tar.bz2

# ocaml-pcre:
# 	$(WGET) http://hg.ocaml.info/release/pcre-ocaml/archive/release-6.2.5.tar.gz
# 	tar xfvz release-6.2.5.tar.gz
# 	mv pcre-ocaml-release-6.2.5 ocaml-pcre

ocamlgraph:
	$(WGET) http://ocamlgraph.lri.fr/download/ocamlgraph-1.8.1.tar.gz
	tar xfz ocamlgraph-1.8.1.tar.gz
	mv ocamlgraph-1.8.1 ocamlgraph

ocaml-re:
	$(WGET) https://transfert.inria.fr/fichiers/1ddcb82a1ba337fe32aabfaf4621d3e5/ocaml-re.tar.bz2
	tar xfj ocaml-re.tar.bz2

clean:
	rm -rf *~

distclean: clean
	rm -rf cudf extlib ocaml-re ocamlgraph dose ocaml-arg
	rm -rf *.tar.gz
	rm -rf *.bz2

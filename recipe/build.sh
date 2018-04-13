#!/bin/bash
./configure -prefix $PREFIX
make world.opt
make tests
make install
echo $PREFIX
head -n 1 $PREFIX/bin/ocamldebug
head -n 1 $PREFIX/bin/ocamldoc
# This file should be binary
# head -n 1 $PREFIX/bin/ocamldoc.opt
file $PREFIX/bin/ocamldebug
file $PREFIX/bin/ocamldoc
file $PREFIX/bin/ocamldoc.opt

#!/bin/bash
./configure -prefix $PREFIX
make world.opt
make tests
make install
echo $PREFIX
head -n 1 $PREFIX/bin/ocamldebug
head -n 1 $PREFIX/bin/ocamldoc

#!/bin/bash
bash -x ./configure -prefix $PREFIX -cc $CC
make world.opt ASPP="$CC -c"
make tests
make install

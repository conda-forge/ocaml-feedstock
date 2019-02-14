#!/bin/bash
export CC=$(basename "$CC")
bash -x ./configure -prefix $PREFIX -cc $CC -aspp "$CC -c" -as "$AS"
make world.opt
make tests
make install

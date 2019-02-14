#!/bin/bash
export CC=$(basename "$CC")
bash -x ./configure -prefix $PREFIX -cc $CC -aspp "$CC -c" -as "$AS"
make world.opt -j${CPU_COUNT}
make tests
make install

#!/bin/bash
export CC=$(basename "$CC")
HASHBANGSCRIPTS=false
bash -x ./configure -prefix $PREFIX -cc $CC -aspp "$CC -c" -as "$AS"
make world.opt -j${CPU_COUNT} HASHBANGSCRIPTS=${HASHBANGSCRIPTS}
make tests HASHBANGSCRIPTS=${HASHBANGSCRIPTS}
make install HASHBANGSCRIPTS=${HASHBANGSCRIPTS}

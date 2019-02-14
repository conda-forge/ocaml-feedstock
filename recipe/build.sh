#!/bin/bash
export CC=$(basename "$CC")
if [[ "$(uname)" == "Linux" ]]; then
   HASHBANGSCRIPTS=false
else
   HASHBANGSCRIPTS=true
fi
bash -x ./configure -prefix $PREFIX -cc $CC -aspp "$CC -c" -as "$AS"
make world.opt -j${CPU_COUNT} HASHBANGSCRIPTS=${HASHBANGSCRIPTS}
make tests HASHBANGSCRIPTS=${HASHBANGSCRIPTS}
make install HASHBANGSCRIPTS=${HASHBANGSCRIPTS}

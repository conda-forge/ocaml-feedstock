#!/bin/bash
export CC=$(basename "$CC")
bash -x ./configure -prefix $PREFIX -cc $CC -aspp "$CC -c" -as "$AS"
make world.opt -j${CPU_COUNT} HASHBANGSCRIPTS=false
make tests HASHBANGSCRIPTS=false
make install HASHBANGSCRIPTS=false

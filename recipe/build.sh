#!/bin/bash
set -euo pipefail
./configure -prefix $PREFIX
make world.opt
LINKFLAGS="" make -C testsuite all
make install

#!/bin/bash
set -euo pipefail
./configure -prefix $PREFIX
make world.opt
make -C testsuite all
make install

#!/bin/bash
bash -x ./configure -prefix $PREFIX -cc $CC
make world.opt
make tests
make install

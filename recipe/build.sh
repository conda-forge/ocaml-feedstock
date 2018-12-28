#!/bin/bash
bash -x ./configure -prefix $PREFIX
make world.opt
make tests
make install

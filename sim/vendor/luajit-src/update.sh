#!/bin/sh

set -eux

cd luajit2
git pull
git show -s --format=%ct > ../luajit_relver.txt

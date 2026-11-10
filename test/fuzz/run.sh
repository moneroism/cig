#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# run.sh - build and run the fuzz targets for cig's own C code (see fuzz.c). Builds outside
# the checkout; corpus and findings in $FUZZ_OUT (default ~/.cache/cig/fuzz). Normal user only.
#   test/fuzz/run.sh build                      build every target
#   test/fuzz/run.sh <target> [seconds]         fuzz one target (default 600 s)
#   test/fuzz/run.sh all [seconds]              every target, one after another
#   test/fuzz/run.sh repro <target> <file>...   run saved inputs once (no fork)
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
repo=$(readlink -f "$here/../..")
out=${FUZZ_OUT:-$HOME/.cache/cig/fuzz}
bin=$out/bin
src=$repo/src
targets="answers pkginfo elf license disk"

[ "$(id -u)" != 0 ] || { echo "run.sh: not as root" >&2; exit 2; }

CFLAGS="-std=gnu17 -D_DEFAULT_SOURCE -O1 -g -fno-omit-frame-pointer -Wall -Wextra -Wno-unused-parameter
        -fsanitize=undefined,bounds -fsanitize-trap=all -fsanitize-coverage=trace-pc
        -fstack-protector-all -D_FORTIFY_SOURCE=3"
LDFLAGS="-Wl,--wrap=exit"

build_one() {
    local t=$1 objs=() f
    case $t in
        answers) objs=("$src"/installer/{ui,diskui,disk,install,sys,libreui}.c "$src/libre/libre.c") ;;
        pkginfo) objs=("$src"/smoke/{util,sha256,inventory,remove,audit}.c "$src/libre/libre.c") ;;
        elf)     objs=("$src"/smoke/{util,sha256,inventory,install,remove}.c "$src/libre/libre.c") ;;
        license) objs=() ;;
        disk)    objs=("$src/installer/disk.c") ;;
        *) echo "run.sh: unknown target $t (one of: $targets)" >&2; exit 2 ;;
    esac
    local d=$bin/$t.o
    rm -rf "$d"; mkdir -p "$d"
    # shellcheck disable=SC2086
    cc -std=gnu17 -O2 -g -Wall -Wextra -c -o "$d/driver.o" "$here/fuzz.c"   # the driver: no coverage, no sanitizers (its allocator works outside object bounds on purpose)
    cc $CFLAGS -I"$here" -c -o "$d/target.o" "$here/t_$t.c"
    for f in "${objs[@]}"; do
        cc $CFLAGS -c -o "$d/$(basename "$(dirname "$f")")-$(basename "$f" .c).o" "$f"
    done
    local libs=()
    [ "$t" != answers ] || libs=(-lncursesw)
    cc $CFLAGS $LDFLAGS -o "$bin/fuzz-$t" "$d"/*.o "${libs[@]}"
    echo "built $bin/fuzz-$t"
}

seed() {   # starting inputs for an empty corpus
    local t=$1 c=$out/corpus/$1
    mkdir -p "$c"
    [ -z "$(ls -A "$c")" ] || return 0
    [ ! -d "$here/seeds/$t" ] || cp "$here/seeds/$t"/* "$c/"
    case $t in
        elf)   # small real programs: DT_NEEDED and RUNPATH
            printf 'int main(void){return 0;}\n' > "$out/seed.c"
            cc -Os -s -o "$c/plain" "$out/seed.c"
            cc -Os -s -Wl,-rpath,/usr/lib/a:/opt/b -Wl,--enable-new-dtags -o "$c/runpath" "$out/seed.c" -lm
            cc -Os -s -Wl,-rpath,/x -Wl,--disable-new-dtags -o "$c/rpath" "$out/seed.c" -lm
            rm -f "$out/seed.c" ;;
        disk)
            { cat "$src/installer/test/fixture.dump"; printf '\n%%%%\n1G rest 512M 40G\n%%%%\n'
              printf '\x00\x01\x28\x02\x01\x00\x00\x00\x01\x02\x01\x00\x03\x01\x01\x00\x06\x00\x00\x00'; } > "$c/fixture" ;;
    esac
}

fuzz_one() {
    local t=$1 secs=${2:-600}
    [ -x "$bin/fuzz-$t" ] || build_one "$t"
    seed "$t"
    mkdir -p "$out/findings/$t"
    echo "== $t ($secs s): corpus $out/corpus/$t, findings $out/findings/$t"
    # the scratch folder is the working directory: nothing relative lands in the repository
    mkdir -p "$out/work/$t"
    (cd "$out/work/$t" && FUZZ_REPO=$repo "$bin/fuzz-$t" "$out/corpus/$t" "$out/findings/$t" "$secs") || true
    ls "$out/findings/$t"
}

case ${1:-} in
    build) for t in $targets; do build_one "$t"; done ;;
    all)   for t in $targets; do fuzz_one "$t" "${2:-600}"; done ;;
    repro) shift; t=$1; shift; [ -x "$bin/fuzz-$t" ] || build_one "$t"
           FUZZ_REPO=$repo "$bin/fuzz-$t" -r "$@" ;;
    "")    sed -n '4,9p' "$0"; exit 2 ;;
    *)     fuzz_one "$1" "${2:-600}" ;;
esac

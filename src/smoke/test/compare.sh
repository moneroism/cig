#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# compare.sh <work dir> - run the shell smoke and the C smoke side by side on two
# scratch roots (SMOKE_ROOT) and compare output, exit codes and the resulting trees.
# <work dir>/pkgs must hold package files matching the current recipes.
# Never touches the real system: everything happens below <work dir>.

set -uo pipefail
REPO=$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)
W=$(readlink -f "${1:?usage: compare.sh <work dir with pkgs/>}")
[ -d "$W/pkgs" ] || { echo "no $W/pkgs"; exit 1; }
export LC_ALL=C
fails=0 steps=0

for impl in sh c; do
    rm -rf "$W/root-$impl" "$W/var-$impl"
    mkdir -p "$W/root-$impl" "$W/var-$impl/build"
    ln -s "$W/pkgs" "$W/var-$impl/pkgs"
done

bin() { if [ "$1" = c ]; then echo "$REPO/src/smoke/smoke"; else echo "$REPO/smoke"; fi; }

tree() {   # a description of everything below a root, without timestamps
    ( cd "$1" && find . -mindepth 1 ! -path './usr/pkg/INVENTORY.tmp*' -printf '%P|%y|%m|%l\n' | sort
      find . -type f -print0 | sort -z | xargs -0 -r sha256sum )
}

step() {   # step <smoke arguments...>
    local impl
    steps=$((steps + 1))
    for impl in sh c; do
        SMOKE_ROOT="$W/root-$impl" CIG_VAR="$W/var-$impl" CIG_REPO="$REPO" \
            "$(bin $impl)" "$@" > "$W/out-$impl" 2>&1 < /dev/null
        echo "exit $?" >> "$W/out-$impl"
        sed -i "s#$W/root-$impl#ROOT#g; s#$W/var-$impl#VAR#g" "$W/out-$impl"
        # the audit progress line (stderr, redrawn with \r) is not part of the result
        perl -pi -e 's/\r   checking package files: \d+\/\d+ .{30}//g; s/\r {60}\r//g' "$W/out-$impl"
    done
    if ! diff -u "$W/out-sh" "$W/out-c" > "$W/diff-out"; then
        echo "DIFF (output) smoke $*"; sed -n '1,30p' "$W/diff-out"; fails=$((fails + 1))
    fi
    if ! diff -u <(tree "$W/root-sh") <(tree "$W/root-c") > "$W/diff-tree"; then
        echo "DIFF (tree)   smoke $*"; sed -n '1,30p' "$W/diff-tree"; fails=$((fails + 1))
    else
        echo "same          smoke $*  ($(tail -n1 "$W/out-c"))"
    fi
}

both() {   # both <shell command run inside each root>
    local impl
    for impl in sh c; do ( cd "$W/root-$impl" && eval "$1" ); done
}

step list
step install --as explicit foot
step list
step why fontconfig
step files foot
step files dwl
step install --as explicit dwl
step audit
step mark build foot
step install --as explicit foot
step why wayland
# damage: a modified package file, a link replaced by a real file, an unmanaged file
both 'echo x >> usr/pkg/dwl/*/bin/dwl; rm usr/bin/foot; echo x > usr/bin/foot; echo y > usr/bin/stray'
step audit
step audit --quick
both 'rm usr/bin/stray'
step remove foot
step audit --quick
step remove wayland
step remove dwl
step list
step audit --quick
# a hand-edited inventory must stop every write
step install --as explicit busybox
both 'echo "evil 1 explicit - 0 x" >> usr/pkg/INVENTORY'
step install --as explicit bash
step audit --quick

echo "$steps steps, $fails difference(s)"
[ "$fails" -eq 0 ]

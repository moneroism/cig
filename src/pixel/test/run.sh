#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# run.sh - every effect for a while on a large terminal, with every grid access bounds-checked
# (test/instrument.py rewrites grid[...] into a checked accessor that aborts out of bounds).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
python3 instrument.py ../pixel.c "$t/pixel.c"
cc -std=c17 -O1 -g -Wall -Wextra -o "$t/pixel" "$t/pixel.c"
fail=0
for m in 1 2 3; do
    out=$( (sleep "${SECONDS_PER_EFFECT:-10}"; printf 'q') | script -qfc "stty rows 60 cols 200; $t/pixel -m $m -u; echo EXIT=\$?" /dev/null 2>&1 | tr -d '\r')
    r=$(printf '%s' "$out" | grep -o 'OUT OF BOUNDS [0-9-]*\|EXIT=[0-9]*' | tail -1)
    echo "effect $m: $r"
    [ "$r" = EXIT=0 ] || fail=1
done
exit $fail

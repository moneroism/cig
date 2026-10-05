#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# run.sh - the partition scenarios through the shell installer and the C layout code;
# the results (problems found, sfdisk tables) must be identical.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cc -std=c17 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -Wall -Wextra -Wpedantic -Wshadow -Werror -O2 \
   -fsanitize=undefined,bounds -fsanitize-trap=all -o "$t/disk_test" disk_test.c ../disk.c
"$t/disk_test" > "$t/c.txt"
./disk_test.sh > "$t/sh.txt"
diff -u "$t/sh.txt" "$t/c.txt" && echo "identical: $(grep -c '^==' "$t/c.txt") scenarios"

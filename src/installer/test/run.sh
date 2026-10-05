#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# run.sh - the partition scenarios through the layout code; the results (problems found,
# sfdisk tables) must match expected.txt, which matched the shell installer exactly when
# that was retired (2026-10-05).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cc -std=c17 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -Wall -Wextra -Wpedantic -Wshadow -Werror -O2 \
   -fsanitize=undefined,bounds -fsanitize-trap=all -o "$t/disk_test" disk_test.c ../disk.c
"$t/disk_test" > "$t/c.txt"
diff -u expected.txt "$t/c.txt" && echo "as expected: $(grep -c '^==' expected.txt) scenarios"

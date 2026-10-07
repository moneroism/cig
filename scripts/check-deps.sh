#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# check-deps.sh <package.tar.gz>... - every library a package links must come from the
# package itself, musl, or a package in its declared dependencies (depends= in its .PKGINFO,
# followed through the other packages given). An undeclared one works only while something
# else happens to install it, and breaks an install with another selection
# (mesa/libdisplay-info, gpgv/libassuan, file/liblzma). build-media runs it on every package
# the installer can install. Needs readelf (binutils). Exit 1 on a problem.
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: check-deps.sh <package.tar.gz>..." >&2; exit 2; }
command -v readelf >/dev/null || { echo "check-deps: readelf not found (binutils)" >&2; exit 2; }
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

declare -A deps owner dir
for f in "$@"; do
    d="$W/$(basename "$f" .tar.gz)"
    mkdir -p "$d"
    tar -xzf "$f" -C "$d"
    name=$(sed -n 's/^name=//p' "$d/.PKGINFO")
    deps[$name]=$(sed -n 's/^depends="\(.*\)"$/\1/p' "$d/.PKGINFO")
    dir[$name]=$d
    for l in "$d"/usr/lib/*.so*; do          # libraries directly in /usr/lib (files and links)
        [ -e "$l" ] || [ -L "$l" ] || continue
        b=${l##*/}; [ -n "${owner[$b]:-}" ] || owner[$b]=$name
    done
done

closure() {   # closure <name>: the name and everything it depends on, space-separated
    local todo=$1 out=" " p d
    while [ -n "$todo" ]; do
        set -- $todo; p=$1; shift; todo="$*"
        case "$out" in *" $p "*) continue ;; esac
        out="$out$p "
        for d in ${deps[$p]:-}; do todo="$todo $d"; done
    done
    echo "$out"
}

bad=0
for name in $(printf '%s\n' "${!dir[@]}" | sort); do
    base=${dir[$name]}
    c=$(closure "$name")
    while IFS= read -r -d '' f; do
        while read -r lib; do
            p=${owner[$lib]:-}
            [ -n "$p" ] || continue          # in no package's /usr/lib: its own RUNPATH (perl)
            [ "$p" != musl ] || continue      # the C library: under everything
            case "$c" in *" $p "*) continue ;; esac
            echo "$name: /${f#"$base"/} links $lib from $p, which $name does not depend on"
            bad=1
        done < <(readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    done < <(find "$base/usr" -type f -size +1k -print0 2>/dev/null)
done
[ $bad = 0 ] && echo "check-deps: $# packages declare the libraries they link"
exit $bad

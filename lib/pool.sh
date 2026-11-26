# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# pool.sh - prebuilt packages from cig's package pool (a release of moneroism/pool). The pool
# serves package files and one index, INDEX, with its detached signature INDEX.sig, made by a cig
# release key (release-key, the same keys as cig's own updates: lib/sync.sh) with
# scripts/publish-packages.sh. A package file is used only when its SHA256 is the one the
# verified index lists for it; nothing else from the pool is trusted.
#
# INDEX:  # comment lines
#         date <seconds since 1970>        when the index was made
#         <file> <sha256> <name> <KiB>     one line per package file (installed size in KiB)
#
# The newest verified index is kept in $CIG_VAR/pool/INDEX. An index older than that one is
# refused: an old, validly signed index served again would bring back old packages. Prebuilt
# packages come from the pool only while prebuilt is chosen (CIG_PKG_MIRROR set: smoke -p, the
# installer's prebuilt choice); CIG_POOL_URL= (empty) turns the pool off.

CIG_POOL_URL=${CIG_POOL_URL-https://github.com/moneroism/pool/releases/download/packages}

# pool_get <name> <out>: from CIG_POOL_DIR (a folder holding the pool's files: tests, a local
# copy) or from the pool on the network
pool_get() {
    if [ -n "${CIG_POOL_DIR:-}" ]; then
        [ -f "$CIG_POOL_DIR/$1" ] && cp "$CIG_POOL_DIR/$1" "$2"
    else
        fetch "$CIG_POOL_URL/$1" "$2" 2>/dev/null
    fi
}

# pool_index: a verified index in $CIG_VAR/pool/INDEX, fetched again when the kept one is more
# than 10 minutes old (one smoke command calls cigbuild once per package). Returns 1 when there
# is none (offline and none kept, refused, no release key or gpgv).
pool_index() {
    local idx="$CIG_VAR/pool/INDEX" d rc old new
    [ -n "$CIG_POOL_URL${CIG_POOL_DIR:-}" ] || return 1
    mkdir -p "$CIG_VAR/pool"
    if [ -s "$idx" ] && [ -n "$(find "$idx" -mmin -10 2>/dev/null)" ]; then return 0; fi
    d=$(mktemp -d "${TMPDIR:-/tmp}/cig-pool.XXXXXX")
    if ! pool_get INDEX "$d/INDEX" || ! pool_get INDEX.sig "$d/INDEX.sig"; then
        rm -rf "$d"
        if [ -s "$idx" ]; then warn "cig's package pool cannot be reached: using the index checked before"; return 0; fi
        warn "cig's package pool cannot be reached (offline?): ${CIG_POOL_DIR:-$CIG_POOL_URL}"; return 1
    fi
    rc=0; release_verify "$d/INDEX.sig" "$d/INDEX" > /dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -rf "$d"
        [ "$rc" -eq 2 ] || warn "THE PACKAGE POOL'S INDEX DID NOT VERIFY: no valid signature by a cig release key. Nothing from it was used."
        return 1
    fi
    new=$(awk '$1 == "date" { print $2; exit }' "$d/INDEX")
    old=$([ -s "$idx" ] && awk '$1 == "date" { print $2; exit }' "$idx" || echo 0)
    case "$new" in ''|*[!0-9]*) rm -rf "$d"; warn "the package pool's index has no date: refused"; return 1 ;; esac
    if [ "$new" -lt "${old:-0}" ]; then
        rm -rf "$d"; warn "the package pool offers an older index than the one checked before: refused"; return 1
    fi
    mv "$d/INDEX" "$idx.new" && mv "$idx.new" "$idx"
    rm -rf "$d"
    # installed sizes for smoke list -a
    awk '!/^#/ && NF == 4 { print $3, $4 }' "$idx" | sort -u > "$CIG_VAR/pool/sizes"
    return 0
}

# pool_fetch <package file path>: that file from the pool, checked against the verified index
pool_fetch() {
    local f=$1 base=${1##*/} want have
    pool_index || return 1
    want=$(awk -v f="$base" '!/^#/ && $1 == f { print $2; exit }' "$CIG_VAR/pool/INDEX")
    [ -n "$want" ] || return 1
    info "$base: from cig's package pool"
    pool_get "$base" "$f.part" || { rm -f "$f.part"; warn "$base could not be downloaded from the package pool"; return 1; }
    have=$(sha256sum "$f.part" | cut -d' ' -f1)
    if [ "$have" != "$want" ]; then
        rm -f "$f.part"; warn "$base from the package pool does not match its SHA256 in the signed index: not used"; return 1
    fi
    mv "$f.part" "$f"
    echo "$have  $base" > "$f.sha256"
}

# prebuilt_get <package file path>: a prebuilt package, while prebuilt is chosen: from the
# local prebuilt packages (CIG_PKG_MIRROR: install media, kept packages) or from the pool
prebuilt_get() {
    local f=$1
    [ ! -f "$f" ] || return 0
    [ -n "${CIG_PKG_MIRROR:-}" ] || return 1
    if [ -f "$CIG_PKG_MIRROR/${f##*/}" ]; then cp "$CIG_PKG_MIRROR/${f##*/}" "$f"; return 0; fi
    pool_fetch "$f"
}

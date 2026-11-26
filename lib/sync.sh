# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# sync.sh - cig's own updates: the newest cig release (recipes, cigbuild, smoke's source),
# checked with gpgv against cig's release key before anything in it is used.
#
# Every release carries cig-release.tar.gz (git archive of the signed tag vVERSION, one folder
# cig-VERSION/) and its detached signature cig-release.tar.gz.sig, both made by
# scripts/sign-release.sh. The keys allowed to sign are the fingerprints in release-key, their
# public halves in keys/<fingerprint>.gpg. The installed release decides which keys the next
# one may be signed by: a new key arrives in a release signed by a key already trusted.
# A release older than the installed one is refused (an old, validly signed release served
# again would bring back fixed bugs).
#
# smoke update runs `cigbuild sync` first and then plans against the verified tree, so cig's
# own tools (cig-tools) are rebuilt like any other package whose recipe changed.

CIG_SYNC_URL=${CIG_SYNC_URL:-https://github.com/moneroism/cig/releases/latest/download}

release_keys() {
    [ -f "$CIG_REPO/release-key" ] || return 0
    awk '!/^#/ && NF { print $1 }' "$CIG_REPO/release-key"
}

# release_verify <signature> <file>: prints the fingerprint of the cig release key that made a
# valid signature of the file (gpgv against release-key's keys only). 1 = no valid signature by
# a release key (or a listed key missing in keys/), 2 = cannot be checked here (no release key
# yet, no gpgv). Used for cig's releases and for the package pool's index (lib/pool.sh).
release_verify() {
    local keys k d out signer
    keys=$(release_keys)
    [ -n "$keys" ] || { warn "nothing can be checked against cig's release key: none in $CIG_REPO/release-key yet"; return 2; }
    command -v gpgv >/dev/null || { warn "cig's release signatures cannot be checked without gpgv (smoke add gpgv)"; return 2; }
    d=$(mktemp -d "${TMPDIR:-/tmp}/cig-verify.XXXXXX")
    for k in $keys; do
        [ -s "$CIG_REPO/keys/$k.gpg" ] || { rm -rf "$d"; warn "release key $k is not in keys/"; return 1; }
        cat "$CIG_REPO/keys/$k.gpg" >> "$d/keyring.gpg"
    done
    mkdir "$d/gnupg"; chmod 700 "$d/gnupg"
    out=$(gpgv --homedir "$d/gnupg" --keyring "$d/keyring.gpg" --status-fd 1 "$1" "$2" 2>/dev/null || true)
    rm -rf "$d"
    # status lines only: VALIDSIG's last field is the primary key's fingerprint
    signer=$(echo "$out" | awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $NF; exit }')
    case " $(echo $keys) " in
        *" ${signer:-none} "*) echo "$signer"; return 0 ;;
    esac
    return 1
}

# sync_get <name> <out>: from CIG_SYNC_DIR (a folder holding a release's files: offline
# updates, tests) or from the release on the network
sync_get() {
    if [ -n "${CIG_SYNC_DIR:-}" ]; then
        [ -f "$CIG_SYNC_DIR/$1" ] && cp "$CIG_SYNC_DIR/$1" "$2"
    else
        fetch "$CIG_SYNC_URL/$1" "$2" 2>/dev/null
    fi
}

# sync_changes <old repo> <new repo>: which recipes a release adds, changes or removes
sync_changes() {
    local old=$1 new=$2 p added= changed= removed=
    for p in $( (ls "$old/packages"; ls "$new/packages") | sort -u); do
        if [ ! -f "$old/packages/$p/recipe" ]; then added="$added $p"
        elif [ ! -f "$new/packages/$p/recipe" ]; then removed="$removed $p"
        elif ! diff -r "$old/packages/$p" "$new/packages/$p" >/dev/null 2>&1; then changed="$changed $p"
        fi
    done
    [ -z "$changed" ] || echo "  recipes changed:$changed" | fold -s -w 96
    [ -z "$added" ] || echo "  recipes added:$added" | fold -s -w 96
    [ -z "$removed" ] || echo "  recipes removed:$removed" | fold -s -w 96
    for p in cigbuild lib src/smoke; do
        diff -r "$old/$p" "$new/$p" >/dev/null 2>&1 || echo "  cig's tools changed: $p"
    done
    return 0
}

# cig_sync [--check]: fetch and verify the newest release. Exit status: 0 = verified (a newer
# release is ready in $CIG_VAR/repo, its folder named in $CIG_VAR/repo/READY; --check keeps
# nothing) or nothing newer; 1 = refused (no valid signature by a release key, an older
# release, a malformed archive); 2 = cannot be checked here (no release key yet, no gpgv,
# offline).
cig_sync() {
    local check=${1:-} d signer rc new cur top
    [ -z "$check" ] && rm -f "$CIG_VAR/repo/READY"
    [ -n "$(release_keys)" ] || { warn "cig updates cannot be checked: no release key in $CIG_REPO/release-key yet"; return 2; }
    command -v gpgv >/dev/null || { warn "cig updates cannot be checked without gpgv (smoke add gpgv)"; return 2; }
    d=$(mktemp -d "${TMPDIR:-/tmp}/cig-sync.XXXXXX")
    info "checking for a new cig release"
    if ! sync_get cig-release.tar.gz "$d/cig-release.tar.gz" || ! sync_get cig-release.tar.gz.sig "$d/cig-release.tar.gz.sig"; then
        rm -rf "$d"; warn "no cig release could be downloaded (offline, or the newest release has no cig-release.tar.gz): $CIG_SYNC_URL"; return 2
    fi
    rc=0; signer=$(release_verify "$d/cig-release.tar.gz.sig" "$d/cig-release.tar.gz") || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -rf "$d"
        [ "$rc" -eq 2 ] && return 2
        warn "THE CIG RELEASE DID NOT VERIFY: no valid signature by a cig release key ($(echo $(release_keys))). Nothing was used."; return 1
    fi
    mkdir "$d/x"
    tar -xzof "$d/cig-release.tar.gz" -C "$d/x" || { rm -rf "$d"; warn "the cig release archive does not unpack"; return 1; }
    top=$(ls "$d/x")
    new=$(cat "$d/x/$top/VERSION" 2>/dev/null || true)
    if ! echo "$new" | grep -qx '[0-9]\{1,4\}\.[0-9]\{1,4\}\.[0-9]\{1,4\}' || [ "$top" != "cig-$new" ]; then
        rm -rf "$d"; warn "the cig release archive is malformed (folder '$top', version '$new')"; return 1
    fi
    cur=$(cat "$CIG_REPO/VERSION")
    if [ "$new" = "$cur" ]; then
        rm -rf "$d"; info "cig $cur is the newest release (signature checked)"; return 0
    fi
    if [ "$(printf '%s\n%s\n' "$cur" "$new" | ver_sort | tail -1)" != "$new" ]; then
        rm -rf "$d"; warn "the release offered (cig $new) is older than the installed cig $cur: refused"; return 1
    fi
    info "new cig release: $cur -> $new (signed by $signer)"
    sync_changes "$CIG_REPO" "$d/x/$top"
    if [ -n "$check" ]; then rm -rf "$d"; return 0; fi
    mkdir -p "$CIG_VAR/repo"
    rm -rf "$CIG_VAR/repo/cig-"*
    mv "$d/x/$top" "$CIG_VAR/repo/$top"
    chmod -R u+rwX,go+rX,go-w "$CIG_VAR/repo/$top"
    rm -rf "$d"
    echo "$CIG_VAR/repo/$top" > "$CIG_VAR/repo/READY"
    return 0
}

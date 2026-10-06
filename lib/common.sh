# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# lib/common.sh - shared code for cigbuild.
# Layout under $CIG_VAR (default /var/cig):
#   sources/   downloaded, verified source archives
#   build/     per-package build trees (temporary)
#   pkgs/      finished packages: <name>-<version>-<rel>.tar.gz
#   (installed packages are managed by smoke: /usr/pkg/INVENTORY)
#   logs/      build logs

die()  { echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "   ! $*" >&2; }

export LC_ALL=POSIX
export PATH=/usr/bin:/usr/sbin
export MAKEFLAGS="-j$(nproc)"
export CFLAGS="${CFLAGS:--O2 -pipe}"
export CXXFLAGS="${CXXFLAGS:--O2 -pipe}"
export LDFLAGS="${LDFLAGS:--Wl,-z,relro,-z,now}"
umask 022
export PYTHONDONTWRITEBYTECODE=1   # no bytecode caches written into /usr

mkdir -p "$CIG_VAR"/{sources,build,pkgs,db,logs}
. "$CIG_REPO/lib/hardware.sh"
. "$CIG_REPO/lib/fixlinks.sh"

# packages that come from bootstrap/, not from recipes
BOOTSTRAP_PROVIDES=" "   # everything has a recipe now

# ---------------- recipes ----------------

recipe_path() { echo "$CIG_REPO/packages/$1/recipe"; }

load_recipe() {
    local f; f=$(recipe_path "$1")
    [ -f "$f" ] || die "no recipe: packages/$1/recipe"
    # reset everything a recipe may set
    name= version= rel=1 source= signature= sha256= depends= makedepends= style=
    configure_args= meson_args= make_args= wrksrc= keep_static= nostrip= config_files= link_dirs= copy_files= noextract= track= upstream= stable= keys=
    unset -f pre_build do_build do_install post_install upstream_version 2>/dev/null || true
    PKGDIR="$CIG_REPO/packages/$1"
    # shellcheck disable=SC1090
    . "$f"
    [ "$name" = "$1" ] || die "recipe packages/$1 says name=$name"
    [ -n "$version" ] || die "$1: version not set"
    [ -n "$style" ] || die "$1: style not set (gnu, meson, make, custom)"
    WORK="$CIG_VAR/build/$name"
    DEST="$WORK/dest"
    PKGFILE="$CIG_VAR/pkgs/$name-$version-$rel.tar.gz"
}

# source entries: "url" or "filename::url"
src_name() { case "$1" in *::*) echo "${1%%::*}" ;; *) basename "$1" ;; esac; }
src_url()  { case "$1" in *::*) echo "${1#*::}" ;; *) echo "$1" ;; esac; }

# ---------------- fetch + verify ----------------

# host_ok <url>: dies unless the URL is HTTPS on a host in lib/hosts (forges and projects'
# own official release sites; never SourceForge, generic download sites or mirrors)
host_ok() {
    local url=$1 host
    case "$url" in https://*) ;; *) die "not an HTTPS URL: $url" ;; esac
    host=${url#https://}; host=${host%%/*}; host=${host%%:*}
    awk -v h="$host" '!/^#/ && $1 == h { found = 1 } END { exit !found }' "$CIG_REPO/lib/hosts" \
        || die "$host is not an allowed source host (lib/hosts: forges and projects' own release sites): $url"
}

# fetch <url> <file>: an HTTPS download from an allowed host, whole or not at all (a broken
# download never leaves a file that a later run would checksum)
fetch() {
    local url=$1 out=$2
    host_ok "$url"
    if curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 30 -o "$out.part" "$url"; then
        mv "$out.part" "$out"
        return 0
    fi
    rm -f "$out.part"
    return 1
}

# get_local <file in $CIG_VAR/sources>: a copy from the install media (CIG_SOURCE_MIRROR) or
# the bootstrap, if there is one; only what a build needs is copied, and it is still verified
get_local() {
    local f=$1 m
    for m in ${CIG_SOURCE_MIRROR:-} /sources; do
        if [ ! -s "$f" ] && [ -s "$m/${f##*/}" ]; then cp "$m/${f##*/}" "$f"; fi
    done
    [ -s "$f" ]
}

# gpgv_verify <file> <signature entry>: the upstream signature, checked on this device with
# gpgv against the recipe's own keys (keys/<fingerprint>.gpg in the repository) and no
# others. Returns 2 when it cannot be checked here: no gpgv yet (bootstrap), no keys=, or a
# signed checksum file or tag (still checked through the pinned sha256).
gpgv_verify() {
    local f=$1 e=$2 d sigf out signer k
    command -v gpgv >/dev/null && [ -n "${keys:-}" ] || return 2
    case "$e" in sums=*|tag=*) return 2 ;; esac
    d=$(mktemp -d)
    for k in $keys; do
        [ -s "$CIG_REPO/keys/$k.gpg" ] || { rm -rf "$d"; die "$name: key $k is not in keys/ (on the host: cigbuild keys $name)"; }
        cat "$CIG_REPO/keys/$k.gpg" >> "$d/keyring.gpg"
    done
    sigf="$CIG_VAR/sources/${e##*/}"
    get_local "$sigf" || fetch "$e" "$sigf" || { rm -rf "$d"; die "signature download failed: $e"; }
    case "$e:$f" in   # kernel.org signs the uncompressed tarball
        *.sign:*.xz) out=$(xz -dc "$f" | gpgv --homedir "$d" --keyring "$d/keyring.gpg" --status-fd 1 "$sigf" - 2>/dev/null || true) ;;
        *.sign:*.gz) out=$(gzip -dc "$f" | gpgv --homedir "$d" --keyring "$d/keyring.gpg" --status-fd 1 "$sigf" - 2>/dev/null || true) ;;
        *)           out=$(gpgv --homedir "$d" --keyring "$d/keyring.gpg" --status-fd 1 "$sigf" "$f" 2>/dev/null || true) ;;
    esac
    rm -rf "$d"
    signer=$(echo "$out" | awk '/VALIDSIG/ { p = $NF; if (length(p) < 40) p = $3; print p; exit }')
    [ -n "$signer" ] || die "$name: no valid signature on ${f##*/} by its trusted keys ($keys): tampered, or signed by another key"
    case " $keys " in *" $signer "*) ;; *) die "$name: ${f##*/} is signed by $signer, not by $keys" ;; esac
    return 0
}

# fetch_sources: every source, checked against its pinned sha256 (if the recipe has one) and
# its upstream signature with gpgv (if it has one and gpgv is installed): signed sources need
# no sha256 in the recipe. A source with neither is trusted on first use: its sha256 is
# recorded on this device ($CIG_VAR/tofu) and any later change refuses it.
fetch_sources() {
    local i=0 e f url want have sig ok tofu
    local -a sums sigs
    read -r -a sums <<< "$(echo $sha256)"
    read -r -a sigs <<< "$(echo $signature)"
    for e in $source; do
        f=$(src_name "$e"); url=$(src_url "$e")
        if ! get_local "$CIG_VAR/sources/$f"; then
            info "$name: downloading $f"
            fetch "$url" "$CIG_VAR/sources/$f" || die "download failed: $url"
        fi
        want=${sums[$i]:-}; sig=${sigs[$i]:--}
        [ "$want" != - ] || want=""   # "-": no pin, the signature decides
        have=$(sha256sum "$CIG_VAR/sources/$f" | cut -d' ' -f1)
        if [ -n "$want" ] && [ "$want" != "$have" ]; then
            rm -f "$CIG_VAR/sources/$f"
            die "$name: CHECKSUM MISMATCH for $f (expected $want, got $have). File deleted."
        fi
        ok=0
        if [ "$sig" != - ]; then
            gpgv_verify "$CIG_VAR/sources/$f" "$sig" && ok=1 || [ $? -eq 2 ] \
                || die "$name: signature check failed for $f"
        fi
        if [ -z "$want" ] && [ $ok -eq 0 ]; then
            [ "$sig" = - ] || die "$name: $f has no pinned sha256 and its signature cannot be checked here (needs gpgv and keys=)"
            tofu="$CIG_VAR/tofu/$f.sha256"
            if [ -s "$tofu" ]; then
                if [ "$(cat "$tofu")" != "$have" ]; then
                    rm -f "$CIG_VAR/sources/$f"
                    die "$name: $f CHANGED since its first use here (expected $(cat "$tofu"), got $have). File deleted."
                fi
            else
                mkdir -p "$CIG_VAR/tofu"; echo "$have" > "$tofu"
                warn "$name: $f is not signed upstream and not pinned: trusted on first use (sha256 recorded in $tofu)"
            fi
        fi
        i=$((i + 1))
    done
}

# ---------------- unpack ----------------

unpack_sources() {
    local e f n
    rm -rf "$WORK"; mkdir -p "$WORK/src" "$DEST"
    for e in $source; do
        f="$CIG_VAR/sources/$(src_name "$e")"
        # noextract=1: the recipe unpacks what it needs itself (e.g. linux-firmware)
        [ -n "$noextract" ] && continue
        case "$f" in
            *.tar*|*.tgz) tar -C "$WORK/src" -xf "$f" ;;
            *.zip)        unzip -q -d "$WORK/src" "$f" ;;
            *)            cp "$f" "$WORK/src/" ;;
        esac
    done
    if [ -n "$wrksrc" ]; then
        SRCDIR="$WORK/src/$wrksrc"
    else
        n=$(find "$WORK/src" -mindepth 1 -maxdepth 1 | wc -l)
        if [ "$n" -eq 1 ] && [ -d "$(find "$WORK/src" -mindepth 1 -maxdepth 1)" ]; then
            SRCDIR=$(find "$WORK/src" -mindepth 1 -maxdepth 1)
        else
            SRCDIR="$WORK/src"
        fi
    fi
    [ -d "$SRCDIR" ] || die "$name: source dir $SRCDIR not found (set wrksrc)"
}

# ---------------- post-processing of $DEST ----------------

normalize_dest() {
    local d t f
    # merged /usr: /bin, /sbin, /lib, /lib64 go under /usr
    for d in bin sbin lib lib64; do
        if [ -d "$DEST/$d" ] && [ ! -L "$DEST/$d" ]; then
            t=$d; [ "$d" = lib64 ] && t=lib
            mkdir -p "$DEST/usr/$t"; cp -a "$DEST/$d/." "$DEST/usr/$t/"; rm -rf "${DEST:?}/$d"
        fi
    done
    [ -d "$DEST/usr/lib64" ] && { cp -a "$DEST/usr/lib64/." "$DEST/usr/lib/"; rm -rf "$DEST/usr/lib64"; }
    fix_links
    # no documentation is shipped
    rm -rf "$DEST"/usr/share/{doc,info,man,gtk-doc}
    find "$DEST" -name '*.la' -delete
    [ -n "$keep_static" ] || find "$DEST" -name '*.a' -delete
    if [ -z "$nostrip" ]; then
        find "$DEST" -type f | while read -r f; do
            head -c 4 "$f" 2>/dev/null | grep -q 'ELF' || continue
            strip --strip-unneeded "$f" 2>/dev/null || true
        done
    fi
}

make_package() {
    local tmp="$WORK/meta"
    # everything a package installs belongs to root, whoever built it
    chown -R root:root "$DEST"
    chmod -R go-w "$DEST"     # nobody but root may change installed files
    rm -rf "$tmp"; mkdir -p "$tmp"
    {
        echo "name=$name"; echo "version=$version"; echo "rel=$rel"
        echo "depends=\"$depends\""
        echo "gpus=\"$(cig_gpus)\""
        echo "config_files=\"$(echo $config_files)\""
        echo "link_dirs=\"$(echo $link_dirs)\""
        echo "copy_files=\"$(echo $copy_files)\""
        echo "built=$(date -u +%Y-%m-%dT%H:%MZ)"
    } > "$DEST/.PKGINFO"
    ( cd "$DEST" && find . \( -type f -o -type l \) ! -name '.PKGINFO' ! -name '.FILES' ! -name '.INSTALL' \
        | sed 's#^\./##' | sort ) > "$DEST/.FILES"
    if declare -F post_install >/dev/null; then
        declare -f post_install > "$DEST/.INSTALL"
    fi
    tar -C "$DEST" -czf "$PKGFILE.part" .
    mv "$PKGFILE.part" "$PKGFILE"
    sha256sum "$PKGFILE" | sed "s#$CIG_VAR/pkgs/##" > "$PKGFILE.sha256"
}

# ---------------- installed packages (smoke) ----------------

# smoke (C): next to cigbuild when installed (cig-tools), otherwise the installed one with
# this repository's recipes (the dev chroot)
if [ -x "$CIG_REPO/smoke" ]; then SMOKE="$CIG_REPO/smoke"; else SMOKE=/usr/share/cig/smoke; fi
export CIG_REPO CIGBUILD="$CIG_REPO/cigbuild"
is_installed() { "$SMOKE" installed "$1"; }

# ---------------- commands ----------------

BUILDING=" "

pkg_build() {
    local p=$1 d
    case "$BUILDING" in *" $p "*) die "dependency loop at $p";; esac
    BUILDING="$BUILDING$p "
    load_recipe "$p"
    # a prebuilt package from the install media (CIG_PKG_MIRROR, set only when the
    # user chose prebuilt packages): copied only when it is actually installed
    if [ ! -f "$PKGFILE" ] && [ -n "${CIG_PKG_MIRROR:-}" ] && [ -f "$CIG_PKG_MIRROR/${PKGFILE##*/}" ]; then
        cp "$CIG_PKG_MIRROR/${PKGFILE##*/}" "$PKGFILE"
    fi
    if [ -f "$PKGFILE" ]; then info "$name $version-$rel: package exists"; BUILDING=${BUILDING/ $p / }; return; fi
    # dependencies must be installed before we can build
    # Building happens on THIS machine, so everything needed to build must be
    # installed here - even when installing into another root (SMOKE_ROOT, the
    # installer). The target only receives runtime dependencies (smoke does that).
    for d in $depends; do
        SMOKE_ROOT= "$SMOKE" installed "$d" || SMOKE_ROOT= "$SMOKE" install --as dependency "$d"
    done
    for d in $makedepends; do
        SMOKE_ROOT= "$SMOKE" installed "$d" || SMOKE_ROOT= "$SMOKE" install --as build "$d"
    done
    load_recipe "$p"
    fetch_sources
    info "$name $version-$rel: building (log: $CIG_VAR/logs/$name.log)"
    local rc
    set +e
    (
        set -euo pipefail
        unpack_sources
        cd "$SRCDIR"
        if declare -F pre_build >/dev/null; then pre_build; fi
        if declare -F do_build  >/dev/null; then do_build;  else style_build;  fi
        cd "$SRCDIR"
        if declare -F do_install >/dev/null; then do_install; else style_install; fi
        normalize_dest
        make_package
    ) > "$CIG_VAR/logs/$name.log" 2>&1
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then
        tail -n 40 "$CIG_VAR/logs/$name.log"
        die "$name: build failed. Full log: $CIG_VAR/logs/$name.log"
    fi
    rm -rf "$WORK"
    info "$name $version-$rel: packaged"
    BUILDING=${BUILDING/ $p / }
}

pkg_rebuild() {   # build again from source, smoke switches to the new build
    load_recipe "$1"
    rm -f "$PKGFILE" "$PKGFILE.sha256"
    pkg_build "$1"
    "$SMOKE" install --as keep "$1"
}

pkg_meta() {      # fields smoke needs, for packages built before they were recorded
    load_recipe "$1"
    printf 'config_files="%s"\nlink_dirs="%s"\ncopy_files="%s"\n' \
        "$(echo $config_files)" "$(echo $link_dirs)" "$(echo $copy_files)"
}

# verify_sig <file> <sigfile>: GPG check (keys fetched from keyservers as needed)
# gpg_check <what> <command...>: run a GPG verification (any command that prints GPG status
# lines on stdout); a missing key is fetched by its ID and the check repeated. Sets SIGNER
# (the signing key's fingerprint); dies on a bad or unverifiable signature.
gpg_check() {
    local what=$1 out key ks; shift
    out=$("$@" 2>&1 || true)
    if echo "$out" | grep -q NO_PUBKEY; then
        key=$(echo "$out" | awk '/NO_PUBKEY/ {print $NF; exit}')
        for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org hkps://pgp.mit.edu; do
            gpg --homedir "$GH" --keyserver "$ks" --recv-keys "$key" >/dev/null 2>&1 && break
        done
        out=$("$@" 2>&1 || true)
    fi
    echo "$out" | grep -q BADSIG && die "BAD SIGNATURE on $what"
    # the primary key's fingerprint (the last VALIDSIG field), so signing subkeys of the same
    # key count as the same signer; old keys without it: the signing key itself
    SIGNER=$(echo "$out" | awk '/VALIDSIG/ { p = $NF; if (length(p) < 40) p = $3; print p; exit }')
    [ -n "$SIGNER" ] || die "could not verify the signature of $what (key not found?)"
}

gpg_init() {
    command -v gpg >/dev/null || die "gpg not found. Run 'cigbuild pin' on the host (e.g. CIG_VAR=~/.cache/cig ~/cig/cigbuild pin ...)"
    GH="$CIG_VAR/gnupg"
    mkdir -p "$GH"; chmod 700 "$GH"
}

verify_sig() {   # verify_sig <file> <detached signature>
    local f=$1 sig=$2
    gpg_init
    case "$sig:$f" in
        *.sign:*.xz)   # kernel.org: the signature covers the uncompressed tarball
            gpg_check "$(basename "$f")" sh -c 'xz -dc "$0" | gpg --homedir "$1" --status-fd 1 --verify "$2" -' "$f" "$GH" "$sig" ;;
        *.sign:*.gz)
            gpg_check "$(basename "$f")" sh -c 'gzip -dc "$0" | gpg --homedir "$1" --status-fd 1 --verify "$2" -' "$f" "$GH" "$sig" ;;
        *)
            gpg_check "$(basename "$f")" gpg --homedir "$GH" --status-fd 1 --verify "$sig" "$f" ;;
    esac
}

# verify_source <file> <signature entry>: how a source's authenticity is established at pin
# time (devices then only check the pinned SHA256):
#   <url>                 a detached upstream GPG signature of the file
#   sums=<url>            a GPG-signed checksum file (inline-signed, or with a detached <url>.asc)
#                         listing the file's SHA-256 or SHA-512
#   tag=<git url>#<tag>   a GPG-signed git tag: the archive must hold exactly the tag's tree
#                         (for archives a forge generates from a tag)
# Sets SIGNER and HOW.
verify_source() {
    local f=$1 e=$2 url sumf plain want have tag t top
    case "$e" in
        sums=*)
            url=${e#sums=}; sumf="$CIG_VAR/sources/$(basename "$url")"
            host_ok "$url"
            curl -fsL --proto '=https' --tlsv1.2 -o "$sumf" "$url" || die "checksum file download failed: $url"
            gpg_init
            if curl -fsL --proto '=https' --tlsv1.2 -o "$sumf.asc" "$url.asc" 2>/dev/null; then
                gpg_check "$(basename "$url")" gpg --homedir "$GH" --status-fd 1 --verify "$sumf.asc" "$sumf"
                plain=$sumf
            else
                plain="$sumf.plain"; rm -f "$plain"
                gpg_check "$(basename "$url")" gpg --homedir "$GH" --batch --yes --status-fd 1 --output "$plain" --decrypt "$sumf"
            fi
            want=$(awk -v n="$(basename "$f")" '$2 == n || $2 == "*" n { print $1; exit }' "$plain")
            case ${#want} in
                64)  have=$(sha256sum "$f" | cut -d' ' -f1) ;;
                128) have=$(sha512sum "$f" | cut -d' ' -f1) ;;
                *)   die "$(basename "$url") lists no checksum for $(basename "$f")" ;;
            esac
            [ "$want" = "$have" ] || die "CHECKSUM MISMATCH: $(basename "$f") does not match the signed $(basename "$url")"
            HOW="signed checksum file" ;;
        tag=*)
            url=${e#tag=}; tag=${url##*#}; url=${url%#*}
            command -v git >/dev/null || die "git not found (needed to check a signed tag)"
            host_ok "$url"
            gpg_init
            t=$(mktemp -d)
            git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$url" "$t/repo" \
                || { rm -rf "$t"; die "cannot clone $url at $tag"; }
            gpg_check "tag $tag of $url" env GNUPGHOME="$GH" git -C "$t/repo" verify-tag --raw "$tag"
            mkdir "$t/tag" "$t/arc"
            git -C "$t/repo" archive --format=tar "$tag" | tar -x -C "$t/tag"
            tar -xf "$f" -C "$t/arc"
            top=$(find "$t/arc" -mindepth 1 -maxdepth 1)
            [ "$(echo "$top" | wc -l)" -eq 1 ] && [ -d "$top" ] || top="$t/arc"
            if ! diff -r "$t/tag" "$top" > "$t/diff" 2>&1; then
                head -n 5 "$t/diff" >&2; rm -rf "$t"
                die "$(basename "$f") does not hold exactly the signed tag $tag"
            fi
            rm -rf "$t"
            HOW="signed git tag $tag" ;;
        *)
            sumf="$CIG_VAR/sources/$(basename "$e")"
            [ -s "$sumf" ] || fetch "$e" "$sumf" 2>/dev/null || die "signature download failed: $e"
            verify_sig "$f" "$sumf"
            HOW="GPG signature" ;;
    esac
}

# ---------------- signing keys ----------------
# keys= in a recipe lists the fingerprints (primary keys) that may sign its sources. pin and
# sig record them on first use, like sha256=, and from then on a signature by any other key
# stops the pin: a keyserver hands out whatever key has the signature's key ID, so a valid
# signature alone does not say who signed. A new key is accepted only with `cigbuild trust`.
NEWKEYS=
check_signer() {   # check_signer <pkg> <what was verified>
    local p=$1 what=$2
    if [ -z "${keys:-}" ]; then
        case " $NEWKEYS " in *" $SIGNER "*) ;; *) NEWKEYS="${NEWKEYS:+$NEWKEYS }$SIGNER" ;; esac
        export_key "$SIGNER"
        return 0
    fi
    case " $keys " in *" $SIGNER "*) export_key "$SIGNER"; return 0 ;; esac
    die "SIGNING KEY CHANGED: $what is signed by $SIGNER,
   but $p trusts only: $keys
   Do not continue unless the project announced the new key on its own site (not only the
   download host). Then: cigbuild trust $p $SIGNER, and pin again."
}
# export_key <fingerprint>: the public key into keys/ (what gpgv on a device checks against)
export_key() {
    local k=$1 out="$CIG_REPO/keys/$1.gpg"
    [ ! -s "$out" ] || return 0
    [ -w "$CIG_REPO" ] || return 0
    mkdir -p "$CIG_REPO/keys"
    gpg --homedir "$GH" --export "$k" > "$out.part" 2>/dev/null   # whole key: export-minimal dropped signing subkeys
    if [ -s "$out.part" ]; then mv "$out.part" "$out"; else rm -f "$out.part"; die "cannot export key $k"; fi
}
set_recipe_keys() {   # set_recipe_keys <recipe> <fingerprints>
    local r=$1 k=$2
    if grep -q '^keys=' "$r"; then sed -i "s|^keys=.*|keys=\"$k\"|" "$r"
    else sed -i "/^sha256=/i keys=\"$k\"" "$r"; fi
}
record_keys() {   # after pin/sig/keys: write the keys seen on first use
    local p=$1 r
    [ -z "${keys:-}" ] && [ -n "$NEWKEYS" ] || return 0
    r=$(recipe_path "$p")
    if [ -w "$r" ]; then
        set_recipe_keys "$r" "$NEWKEYS"
        info "$p: signing key(s) recorded: $NEWKEYS"
    else
        echo "keys=\"$NEWKEYS\""
    fi
}
pkg_trust() {   # pkg_trust <pkg> <fingerprint>: accept one more signing key
    local p=$1 fp=${2^^} r
    [[ "$fp" =~ ^[0-9A-F]{40}$ ]] || die "a key fingerprint is 40 hex digits (gpg --fingerprint)"
    load_recipe "$p"
    r=$(recipe_path "$p")
    case " ${keys:-} " in *" $fp "*) info "$p: $fp is already trusted"; return 0 ;; esac
    set_recipe_keys "$r" "${keys:+$keys }$fp"
    warn "$p: now also trusts $fp"
}
pkg_keys() {   # pkg_keys <pkg>: verify the pinned sources again and record their signers
    local p=$1 e f i=0 sig
    local -a sums sigs
    NEWKEYS=
    load_recipe "$p"
    read -r -a sums <<< "$(echo $sha256)"
    read -r -a sigs <<< "$(echo $signature)"
    for e in $source; do
        f=$(src_name "$e"); sig=${sigs[$i]:--}
        if [ "$sig" != - ] && [ -n "${sums[$i]:-}" ]; then
            [ -s "$CIG_VAR/sources/$f" ] || fetch "$(src_url "$e")" "$CIG_VAR/sources/$f" \
                || die "download failed: $(src_url "$e")"
            [ "${sums[$i]}" = - ] || [ "$(sha256sum "$CIG_VAR/sources/$f" | cut -d' ' -f1)" = "${sums[$i]}" ] \
                || die "$p: $f does not match its pinned sha256"
            verify_source "$CIG_VAR/sources/$f" "$sig"
            check_signer "$p" "$f"
            info "$p: $f -> $HOW OK (key $SIGNER)"
        fi
        i=$((i + 1))
    done
    record_keys "$p"
}

pkg_sigonly() {   # pkg_sigonly <pkg>: signed sources drop their pinned sha256 ("-")
    local p=$1 e f i=0 sig new="" r
    local -a sums sigs
    NEWKEYS=
    load_recipe "$p"
    r=$(recipe_path "$p")
    [ -n "${keys:-}" ] || die "$p: no keys= yet (cigbuild keys $p first)"
    read -r -a sums <<< "$(echo $sha256)"
    read -r -a sigs <<< "$(echo $signature)"
    for e in $source; do
        f=$(src_name "$e"); sig=${sigs[$i]:--}
        case "$sig" in
            -|sums=*|tag=*) new="$new ${sums[$i]:-}" ;;   # kept: unsigned, or checked through the pin
            *)
                [ "${sums[$i]:-}" != - ] || { new="$new -"; i=$((i + 1)); continue; }
                [ -s "$CIG_VAR/sources/$f" ] || fetch "$(src_url "$e")" "$CIG_VAR/sources/$f" \
                    || die "download failed: $(src_url "$e")"
                [ "$(sha256sum "$CIG_VAR/sources/$f" | cut -d' ' -f1)" = "${sums[$i]}" ] \
                    || die "$p: $f does not match its pinned sha256"
                verify_source "$CIG_VAR/sources/$f" "$sig"
                check_signer "$p" "$f"
                info "$p: $f -> $HOW OK (key $SIGNER): pin dropped, the signature decides"
                new="$new -" ;;
        esac
        i=$((i + 1))
    done
    new=${new# }
    sed -i "s|^sha256=.*|sha256=\"$new\"|" "$r"
}

pkg_pin() {
    local p=$1 e f have known i=0 new="" changed=0 sig sigf
    local -a sums sigs
    NEWKEYS=
    load_recipe "$p"
    read -r -a sums <<< "$(echo $sha256)"
    read -r -a sigs <<< "$(echo $signature)"
    for e in $source; do
        f=$(src_name "$e")
        if [ -n "${sums[$i]:-}" ]; then new="$new ${sums[$i]}"; i=$((i+1)); continue; fi
        # 1. a checksum recorded when the bootstrap verified this file's signature
        known=$(awk -v f="$f" '$2 == f || $2 == "./" f { print $1; exit }' /sources/SHA256SUMS 2>/dev/null || true)
        if [ -n "$known" ]; then
            have=$known; info "$p: $f -> verified by the bootstrap record"
        else
            [ -s "$CIG_VAR/sources/$f" ] || fetch "$(src_url "$e")" "$CIG_VAR/sources/$f" \
                || die "download failed: $(src_url "$e")"
            have=$(sha256sum "$CIG_VAR/sources/$f" | cut -d' ' -f1)
            sig=${sigs[$i]:--}
            if [ "$sig" != "-" ]; then
                # 2. upstream: a GPG signature, a signed checksum file or a signed git tag
                verify_source "$CIG_VAR/sources/$f" "$sig"
                check_signer "$p" "$f"
                info "$p: $f -> $HOW OK (key $SIGNER)"
                # a detached signature is checked on every device (gpgv): no hash to pin
                case "$sig" in sums=*|tag=*) ;; *) have=- ;; esac
            else
                # 3. nothing to verify against
                warn "$p: $f -> no upstream signature; trusted on first use"
            fi
        fi
        new="$new $have"; changed=1; i=$((i+1))
    done
    new=${new# }
    record_keys "$p"
    if [ $changed -eq 1 ]; then
        if [ -w "$(recipe_path "$p")" ]; then
            sed -i "s|^sha256=.*|sha256=\"$new\"|" "$(recipe_path "$p")"
            info "$p: recipe updated"
        else
            echo "sha256=\"$new\""
        fi
    else
        info "$p: all sources already pinned"
    fi
}

pkg_sig() {   # pkg_sig <pkg> <signature URL | ->...: check pinned sources against upstream signatures, then record them
    local p=$1 e f i=0 n sig sigf r; shift
    local -a sums sigs=("$@")
    NEWKEYS=
    load_recipe "$p"
    r=$(recipe_path "$p")
    read -r -a sums <<< "$(echo $sha256)"
    n=$(echo $source | wc -w)
    [ ${#sigs[@]} -eq "$n" ] || die "$p: give one signature URL (or -) for each of its $n source(s)"
    [ -z "$signature" ] || [ "$(grep -c '^signature=' "$r")" -eq 1 ] && ! grep -q '^signature="[^"]*$' "$r" \
        || die "$p: the recipe's signature= spans several lines; edit it with pin instead"
    for e in $source; do
        f=$(src_name "$e"); sig=${sigs[$i]}
        [ -n "${sums[$i]:-}" ] || die "$p: $f is not pinned yet (cigbuild pin $p)"
        if [ "$sig" != - ]; then
            [ -s "$CIG_VAR/sources/$f" ] || fetch "$(src_url "$e")" "$CIG_VAR/sources/$f" \
                || die "download failed: $(src_url "$e")"
            [ "${sums[$i]}" = - ] || [ "$(sha256sum "$CIG_VAR/sources/$f" | cut -d' ' -f1)" = "${sums[$i]}" ] \
                || die "$p: $f does not match its pinned sha256"
            verify_source "$CIG_VAR/sources/$f" "$sig"
            check_signer "$p" "$f"
            info "$p: $f -> $HOW OK (key $SIGNER)"
        fi
        i=$((i + 1))
    done
    record_keys "$p"
    sig="$*"; sig=${sig//"$version"/'$version'}   # follows the recipe's version on updates
    if grep -q '^signature=' "$r"; then
        sed -i "s|^signature=.*|signature=\"$sig\"|" "$r"
    else
        sed -i "/^sha256=/i signature=\"$sig\"" "$r"
    fi
    info "$p: signature URLs recorded"
}

pkg_info() {
    load_recipe "$1"
    echo "name:     $name"
    echo "version:  $version-$rel"
    echo "style:    $style"
    echo "depends:  ${depends:--}"
    echo "builds with: ${makedepends:--}"
    echo "source:   $source"
    if is_installed "$1"; then echo "installed: yes (smoke why $1)"; else echo "installed: no"; fi
}

pkg_list() { "$SMOKE" list; }

# ---------------- upstream releases ----------------
# A release version: numbers with dots (or underscores in tags), optionally one letter or
# an OpenSSH-style pN at the end. Anything else (rc, alpha, beta, pre, dev) is not stable.
VER_RE='[0-9]+([._][0-9]+)*(p[0-9]+|[a-z])?'

# git_repo_of <source url>: the git repository of a source on a git host, if it can be told
git_repo_of() {
    case "$1" in
        https://github.com/*|https://codeberg.org/*|https://gitlab.com/*)
            echo "$1" | sed -E 's#^(https://[^/]+/[^/]+/[^/]+).*#\1.git#' ;;
        https://gitlab.freedesktop.org/*/-/*)
            echo "${1%%/-/*}.git" ;;
        https://git.sr.ht/*)
            echo "$1" | sed -E 's#^(https://git.sr.ht/[^/]+/[^/]+).*#\1#' ;;
    esac
}

# versions_git <repo> <current>: stable versions from the repository's tags. Tags carry
# prefixes and suffixes (v1.2, libnl3_11_0, pcre2-10.49, json-c-0.19-20260627): they are
# learnt from the tag of the current release, so other tag series in the repository are
# ignored. Underscores and dashes between numbers count as dots.
versions_git() {
    local repo=$1 cur=$2 tags t pre="" suf="" sre="" word="" re v found=0
    tags=$(git ls-remote --tags --refs "$repo" 2>/dev/null | sed 's#.*refs/tags/##') || return 0
    # a release suffix word the current version carries (6.18.54.hardened1 <- v6.18.54-hardened1)
    if [[ "$cur" =~ \.([a-z]+)[0-9]+$ ]]; then word=${BASH_REMATCH[1]}; fi
    re="^$VER_RE${word:+([.]$word[0-9]+)?}\$"
    while read -r t; do   # the current release's tag: its version written with . _ or -
        v=$t
        for sep in . _ -; do
            local c=${cur//./$sep}; [ -z "$word" ] || c=${c%$sep$word*}-$word${cur##*$word}
            if [[ "$t" == *"$c"* ]]; then
                pre=${t%%"$c"*}; suf=${t#*"$c"}
                if [[ "$pre" =~ (^|[^0-9])$ ]] && [[ ! "$suf" =~ ^[0-9] ]]; then found=1; break 2; fi
                pre= suf=
            fi
        done
    done <<< "$tags"
    sre=$(printf '%s' "$suf" | sed 's/[0-9]/[0-9]/g')
    while read -r t; do
        [ -n "$t" ] || continue
        if [ $found = 1 ]; then
            [[ "$t" == "$pre"* ]] || continue
            v=${t#"$pre"}
            if [ -n "$suf" ]; then [[ "$v" =~ ^(.*)$sre$ ]] || continue; v=${BASH_REMATCH[1]}; fi
        else
            v=${t#"${t%%[0-9]*}"}
        fi
        [ -z "$word" ] || v=${v//-$word/.$word}
        v=${v//_/.}; v=${v//-/.}
        if [[ "$v" =~ $re ]]; then echo "$v"; fi
    done <<< "$tags"
    return 0
}

# versions_pypi <source url>: the newest release of a Python package on PyPI
versions_pypi() {
    local n; n=${1##*/}; n=${n%-[0-9]*}
    curl -fsL --proto '=https' --tlsv1.2 --max-time 20 "https://pypi.org/pypi/$n/json" 2>/dev/null \
        | grep -oE '"version": ?"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/'
}

# versions_list <page> <file name> <current>: stable versions named on a download page or
# directory listing. If a directory in the path carries the version (python/3.13.5/), the
# parent directory is listed instead. Only for finding versions: downloads still come from
# the recipe's source and are verified as always, so a GNU mirror may answer when
# ftp.gnu.org is slow.
versions_list() {
    local page=$1 base=$2 cur=$3 pre suf m re html
    if [[ "${page%/*}" == *"$cur"* ]] && [ "$page" != "${upstream:-}" ]; then
        base=${page%%"$cur"*}; base='"'${base##*/}"$cur"; suf=${page#*"$cur"}; base=$base${suf%%/*}/
        page=${page%%"$cur"*}; page=${page%/*}/
    elif [ "$page" != "${upstream:-}" ]; then
        page=${page%/*}/
    fi
    pre=${base%%"$cur"*}; suf=${base#*"$cur"}
    re=$(printf '%s' "$pre" | sed 's/[].[\*^$+?(){}|]/\\&/g')"$VER_RE"$(printf '%s' "$suf" | sed 's/[].[\*^$+?(){}|]/\\&/g')
    html=$(curl -fsL --proto '=https' --tlsv1.2 --max-time 20 "$page" 2>/dev/null) || html=
    if [ -z "$html" ] && [[ "$page" == https://ftp.gnu.org/gnu/* ]]; then
        html=$(curl -fsL --proto '=https' --tlsv1.2 --max-time 30 "https://mirrors.kernel.org/gnu/${page#https://ftp.gnu.org/gnu/}" 2>/dev/null) || html=
    fi
    while read -r m; do
        m=${m#"$pre"}; echo "${m%"$suf"}"
    done < <(printf '%s' "$html" | grep -oE "$re" | sort -u)
}

# ver_sort: version lines, oldest first, the same with GNU and BusyBox (their sort -V differ:
# BusyBox put 6.18.hardened1 after 6.18.54.hardened1). Numbers compare as numbers and sort
# above words, so the base release v6.18-hardened1 is older than 6.18.54.hardened1.
ver_sort() {
    awk '{ k = ""; s = $0
           while (s != "") {
               if (match(s, /^[0-9]+/)) k = k "1" sprintf("%012d", substr(s, 1, RLENGTH) + 0)
               else if (match(s, /^[a-z]+/)) k = k "0" substr(s, 1, RLENGTH)
               else { k = k substr(s, 1, 1); RLENGTH = 1 }
               s = substr(s, RLENGTH + 1)
           }
           print k "\t" $0 }' | LC_ALL=C sort | cut -f2
}

# pkg_latest <pkg>: "<name> <recipe version> <newest upstream> <how>"; how = current, update,
# unknown (nothing found: set upstream= in the recipe: a git repository, or a page that names
# the release files). track=X limits it to the X series, stable=<ERE> to versions that match;
# a recipe may define upstream_version() to print the candidates itself.
pkg_latest() {
    local e url repo cand best
    load_recipe "$1"
    e=$(echo $source | cut -d' ' -f1); url=$(src_url "$e")
    case "${upstream:-}" in
        *.git|https://git.sr.ht/*) repo=$upstream ;;
        "") repo=$(git_repo_of "$url") ;;
        *) repo=; url=$upstream ;;
    esac
    if declare -F upstream_version >/dev/null; then cand=$(upstream_version)
    elif [ -n "$repo" ]; then cand=$(versions_git "$repo" "$version")
    elif [[ "$url" == https://files.pythonhosted.org/* ]]; then cand=$(versions_pypi "$url")
    else cand=$(versions_list "$url" "$(src_name "$e")" "$version"); fi
    if [ -n "${track:-}" ]; then
        cand=$(echo "$cand" | grep -E "^${track//./\\.}([.]|$)" || true)
    fi
    if [ -n "${stable:-}" ]; then cand=$(echo "$cand" | grep -E "$stable" || true); fi
    # dated snapshot tags (20021030) are not releases: the first number may not be much longer
    local n=${version%%[!0-9]*}; n=$(( ${#n} > 3 ? ${#n} : 3 ))
    cand=$(echo "$cand" | grep -E "^[0-9]{1,$n}([.]|[a-z]|p|\$)" || true)
    best=$( (echo "$cand"; echo "$version") | grep -v '^$' | ver_sort | tail -1)
    if [ -z "$cand" ]; then echo "$name $version ? unknown"
    elif [ "$best" = "$version" ]; then echo "$name $version $version current"
    else echo "$name $version $best update"; fi
}

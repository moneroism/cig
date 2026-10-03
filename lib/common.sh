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
    configure_args= meson_args= make_args= wrksrc= keep_static= nostrip= config_files= link_dirs= copy_files=
    unset -f pre_build do_build do_install post_install 2>/dev/null || true
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

fetch_sources() {
    local i=0 e f url want have
    local -a sums; read -r -a sums <<< "$(echo $sha256)"
    for e in $source; do
        f=$(src_name "$e"); url=$(src_url "$e")
        # reuse the copy the bootstrap already downloaded (checksum still enforced)
        if [ ! -s "$CIG_VAR/sources/$f" ] && [ -s "/sources/$f" ]; then
            cp "/sources/$f" "$CIG_VAR/sources/$f"
        fi
        if [ ! -s "$CIG_VAR/sources/$f" ]; then
            info "$name: downloading $f"
            curl -fL --proto '=https' --tlsv1.2 -o "$CIG_VAR/sources/$f.part" "$url" \
                || { rm -f "$CIG_VAR/sources/$f.part"; die "download failed: $url"; }
            mv "$CIG_VAR/sources/$f.part" "$CIG_VAR/sources/$f"
        fi
        want=${sums[$i]:-}
        have=$(sha256sum "$CIG_VAR/sources/$f" | cut -d' ' -f1)
        [ -n "$want" ] || die "$name: no sha256 pinned for $f (got $have). Run: cigbuild pin $name"
        if [ "$want" != "$have" ]; then
            rm -f "$CIG_VAR/sources/$f"
            die "$name: CHECKSUM MISMATCH for $f (expected $want, got $have). File deleted."
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

SMOKE="$CIG_REPO/smoke"
is_installed() { "$SMOKE" installed "$1"; }

# ---------------- commands ----------------

BUILDING=" "

pkg_build() {
    local p=$1 d
    case "$BUILDING" in *" $p "*) die "dependency loop at $p";; esac
    BUILDING="$BUILDING$p "
    load_recipe "$p"
    # dependencies must be installed before we can build
    for d in $depends; do
        is_installed "$d" || "$SMOKE" install --as dependency "$d"
    done
    for d in $makedepends; do
        is_installed "$d" || "$SMOKE" install --as build "$d"
    done
    load_recipe "$p"
    if [ -f "$PKGFILE" ]; then info "$name $version-$rel: package exists"; BUILDING=${BUILDING/ $p / }; return; fi
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
verify_sig() {
    local f=$1 sig=$2 out key ks gh="$CIG_VAR/gnupg"
    command -v gpg >/dev/null || die "gpg not found. Run 'cigbuild pin' on the host (e.g. CIG_VAR=~/.cache/cig ~/cig/cigbuild pin ...)"
    mkdir -p "$gh"; chmod 700 "$gh"
    _gpgv() {
        case "$sig" in
            *.sign)   # kernel.org: signature covers the uncompressed tarball
                case "$f" in
                    *.xz) xz -dc "$f" | gpg --homedir "$gh" --status-fd 1 --verify "$sig" - 2>/dev/null ;;
                    *.gz) gzip -dc "$f" | gpg --homedir "$gh" --status-fd 1 --verify "$sig" - 2>/dev/null ;;
                    *)    gpg --homedir "$gh" --status-fd 1 --verify "$sig" "$f" 2>/dev/null ;;
                esac ;;
            *) gpg --homedir "$gh" --status-fd 1 --verify "$sig" "$f" 2>/dev/null ;;
        esac
    }
    out=$(_gpgv || true)
    if echo "$out" | grep -q NO_PUBKEY; then
        key=$(echo "$out" | awk '/NO_PUBKEY/ {print $3; exit}')
        for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org hkps://pgp.mit.edu; do
            gpg --homedir "$gh" --keyserver "$ks" --recv-keys "$key" >/dev/null 2>&1 && break
        done
        out=$(_gpgv || true)
    fi
    echo "$out" | grep -q BADSIG && die "BAD SIGNATURE on $(basename "$f")"
    SIGNER=$(echo "$out" | awk '/VALIDSIG/ {print $3; exit}')
    [ -n "$SIGNER" ] || die "could not verify the signature of $(basename "$f") (key not found?)"
}

pkg_pin() {
    local p=$1 e f have known i=0 new="" changed=0 sig sigf
    local -a sums sigs
    load_recipe "$p"
    read -r -a sums <<< "$(echo $sha256)"
    read -r -a sigs <<< "$(echo $signature)"
    for e in $source; do
        f=$(src_name "$e")
        if [ -n "${sums[$i]:-}" ]; then new="$new ${sums[$i]}"; i=$((i+1)); continue; fi
        # 1. a checksum recorded when the bootstrap verified this file's signature
        known=$(grep -h "  $f\$" /sources/SHA256SUMS 2>/dev/null | head -n1 | cut -d' ' -f1 || true)
        if [ -n "$known" ]; then
            have=$known; info "$p: $f -> verified by the bootstrap record"
        else
            [ -s "$CIG_VAR/sources/$f" ] || curl -fL --proto '=https' --tlsv1.2 \
                -o "$CIG_VAR/sources/$f" "$(src_url "$e")" || die "download failed: $(src_url "$e")"
            have=$(sha256sum "$CIG_VAR/sources/$f" | cut -d' ' -f1)
            sig=${sigs[$i]:--}
            if [ "$sig" != "-" ]; then
                # 2. upstream GPG signature
                sigf="$CIG_VAR/sources/$(basename "$sig")"
                curl -fsL --proto '=https' --tlsv1.2 -o "$sigf" "$sig" || die "signature download failed: $sig"
                verify_sig "$CIG_VAR/sources/$f" "$sigf"
                info "$p: $f -> GPG signature OK (key $SIGNER)"
            else
                # 3. nothing to verify against
                warn "$p: $f -> no upstream signature; trusted on first use"
            fi
        fi
        new="$new $have"; changed=1; i=$((i+1))
    done
    new=${new# }
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

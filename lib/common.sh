# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# lib/common.sh - shared code for cigbuild.
# Layout under $CIG_VAR (default /var/cig):
#   sources/   downloaded, verified source archives
#   build/     per-package build trees (temporary)
#   pkgs/      finished packages: <name>-<version>-<rel>.tar.gz
#   db/<name>/ installed package: PKGINFO, FILES, INSTALL
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

mkdir -p "$CIG_VAR"/{sources,build,pkgs,db,logs}

# packages that come from bootstrap/, not from recipes
BOOTSTRAP_PROVIDES=" musl binutils gcc linux-headers busybox bash make m4 gawk sinit "

# ---------------- recipes ----------------

recipe_path() { echo "$CIG_REPO/packages/$1/recipe"; }

load_recipe() {
    local f; f=$(recipe_path "$1")
    [ -f "$f" ] || die "no recipe: packages/$1/recipe"
    # reset everything a recipe may set
    name= version= rel=1 source= sha256= depends= makedepends= style=
    configure_args= meson_args= make_args= wrksrc= keep_static= nostrip=
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
    local -a sums; read -r -a sums <<< "$sha256"
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
    rm -rf "$tmp"; mkdir -p "$tmp"
    {
        echo "name=$name"; echo "version=$version"; echo "rel=$rel"
        echo "depends=\"$depends\""
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

# ---------------- database ----------------

is_installed() {
    case "$BOOTSTRAP_PROVIDES" in *" $1 "*) return 0 ;; esac
    [ -f "$CIG_VAR/db/$1/PKGINFO" ]
}
installed_version() { ( . "$CIG_VAR/db/$1/PKGINFO" && echo "$version-$rel" ); }

# ---------------- commands ----------------

BUILDING=" "

pkg_build() {
    local p=$1 d
    case "$BUILDING" in *" $p "*) die "dependency loop at $p";; esac
    BUILDING="$BUILDING$p "
    load_recipe "$p"
    # dependencies must be installed before we can build
    for d in $depends $makedepends; do
        is_installed "$d" || pkg_install "$d"
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

pkg_install() {
    local p=$1 d tmp f t owner old
    load_recipe "$p"
    if is_installed "$p" && [ -f "$CIG_VAR/db/$p/PKGINFO" ] \
        && [ "$(installed_version "$p")" = "$version-$rel" ]; then
        info "$p $version-$rel: already installed"; return
    fi
    for d in $depends; do is_installed "$d" || pkg_install "$d"; done
    load_recipe "$p"                    # deps above reloaded other recipes
    [ -f "$PKGFILE" ] || pkg_build "$p"
    load_recipe "$p"

    info "$name $version-$rel: installing"
    tmp="$CIG_VAR/build/.install-$name"
    rm -rf "$tmp"; mkdir -p "$tmp"
    tar -C "$tmp" -xzf "$PKGFILE"

    # refuse to overwrite files owned by another package
    while read -r f; do
        for owner in "$CIG_VAR"/db/*/FILES; do
            [ -f "$owner" ] || continue
            [ "$owner" = "$CIG_VAR/db/$name/FILES" ] && continue
            grep -qxF "$f" "$owner" && die "$name: /$f already belongs to $(basename "$(dirname "$owner")")"
        done
    done < "$tmp/.FILES"

    # never write through a BusyBox link
    while read -r f; do
        t="/$f"
        if [ -L "$t" ]; then case "$(readlink "$t")" in *busybox) rm -f "$t" ;; esac; fi
    done < "$tmp/.FILES"

    old=""
    [ -f "$CIG_VAR/db/$name/FILES" ] && old="$CIG_VAR/db/$name/FILES.old" \
        && cp "$CIG_VAR/db/$name/FILES" "$old"

    ( cd "$tmp" && find . -mindepth 1 -maxdepth 1 ! -name '.PKGINFO' ! -name '.FILES' ! -name '.INSTALL' \
        -exec cp -a {} / \; )

    mkdir -p "$CIG_VAR/db/$name"
    cp "$tmp/.PKGINFO" "$CIG_VAR/db/$name/PKGINFO"
    cp "$tmp/.FILES"   "$CIG_VAR/db/$name/FILES"
    rm -f "$CIG_VAR/db/$name/INSTALL"
    [ -f "$tmp/.INSTALL" ] && cp "$tmp/.INSTALL" "$CIG_VAR/db/$name/INSTALL"

    # upgrade: remove files the new version no longer has
    if [ -n "$old" ]; then
        grep -vxF -f "$CIG_VAR/db/$name/FILES" "$old" | while read -r f; do rm -f "/$f"; done || true
        rm -f "$old"
    fi
    rm -rf "$tmp"

    if [ -f "$CIG_VAR/db/$name/INSTALL" ]; then
        bash -c ". '$CIG_VAR/db/$name/INSTALL'; post_install" || warn "$name: post_install failed"
    fi
    info "$name $version-$rel: installed"
}

pkg_remove() {
    local p=$1 other f
    [ -f "$CIG_VAR/db/$p/PKGINFO" ] || die "$p is not installed"
    for other in "$CIG_VAR"/db/*/PKGINFO; do
        [ "$other" = "$CIG_VAR/db/$p/PKGINFO" ] && continue
        ( . "$other"; case " $depends " in *" $p "*) exit 0;; *) exit 1;; esac ) \
            && die "$p is needed by $(basename "$(dirname "$other")")"
    done
    info "$p: removing"
    while read -r f; do rm -f "/$f"; done < "$CIG_VAR/db/$p/FILES"
    # remove directories that became empty (deepest first), never top-level ones
    sed 's#/[^/]*$##' "$CIG_VAR/db/$p/FILES" | sort -ru | while read -r f; do
        case "$f" in usr|usr/*/|etc|var|"") continue ;; esac
        rmdir -p "/$f" 2>/dev/null || true
    done
    rm -rf "$CIG_VAR/db/$p"
    info "$p: removed"
}

pkg_pin() {
    local p=$1 e f have known i=0 new="" changed=0
    local -a sums
    load_recipe "$p"
    read -r -a sums <<< "$sha256"
    for e in $source; do
        f=$(src_name "$e")
        if [ -n "${sums[$i]:-}" ]; then new="$new ${sums[$i]}"; i=$((i+1)); continue; fi
        # prefer a checksum recorded when the bootstrap verified the file's signature
        known=$(grep -h "  $f\$" /sources/SHA256SUMS 2>/dev/null | head -n1 | cut -d' ' -f1 || true)
        if [ -n "$known" ]; then
            have=$known; info "$p: $f -> $have (from the signature-verified bootstrap record)"
        else
            [ -s "$CIG_VAR/sources/$f" ] || curl -fL --proto '=https' --tlsv1.2 \
                -o "$CIG_VAR/sources/$f" "$(src_url "$e")" || die "download failed"
            have=$(sha256sum "$CIG_VAR/sources/$f" | cut -d' ' -f1)
            warn "$p: $f -> $have (trust on first use: check the upstream signature before committing)"
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
    if [ -f "$CIG_VAR/db/$1/PKGINFO" ]; then echo "installed: $(installed_version "$1")"; else echo "installed: no"; fi
}

pkg_list() {
    local d
    for d in "$CIG_VAR"/db/*/PKGINFO; do
        [ -f "$d" ] || continue
        ( . "$d"; printf '%-24s %s-%s\n' "$name" "$version" "$rel" )
    done
}

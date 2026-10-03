# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# lib/styles.sh - build styles. A recipe sets style=..., or defines
# do_build / do_install itself (style=custom).
#   gnu    ./configure && make && make install
#   meson  meson setup && ninja && meson install
#   make   plain Makefile with PREFIX/DESTDIR
#
# Inside build functions: $SRCDIR (source), $DEST (install root, = DESTDIR),
# $PKGDIR (the recipe's folder, for extra files), $WORK (scratch).

# keep only -D options this package version defines; report the rest
meson_known_opts() {
    local a n f
    f=$(ls meson_options.txt meson.options 2>/dev/null | head -n1 || true)
    for a in "$@"; do
        case "$a" in
            -D*=*)
                n=${a#-D}; n=${n%%=*}
                if [ -n "$f" ] && ! grep -qE "option\(['\"]$n['\"]" "$f"; then
                    echo "   (skipping option not defined by this version: $a)" >&2
                    continue
                fi ;;
        esac
        printf '%s\n' "$a"
    done
}

style_build() {
    case "$style" in
        gnu)
            # shellcheck disable=SC2086
            ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
                --disable-static $configure_args
            # shellcheck disable=SC2086
            make $make_args ;;
        meson)
            local -a opts=()
            # shellcheck disable=SC2086
            [ -n "$meson_args" ] && mapfile -t opts < <(meson_known_opts $meson_args)
            meson setup build --prefix=/usr --libdir=lib --buildtype=release \
                --wrap-mode=nodownload "${opts[@]}"
            ninja -C build ;;
        make)
            # shellcheck disable=SC2086
            make PREFIX=/usr $make_args ;;
        custom)
            die "$name: style=custom but no do_build() defined" ;;
        *)  die "$name: unknown style '$style'" ;;
    esac
}

style_install() {
    case "$style" in
        gnu)   # shellcheck disable=SC2086
               make DESTDIR="$DEST" $make_args install ;;
        meson) DESTDIR="$DEST" meson install -C build --no-rebuild ;;
        make)  # shellcheck disable=SC2086
               make PREFIX=/usr DESTDIR="$DEST" $make_args install ;;
        custom) die "$name: style=custom but no do_install() defined" ;;
        *)     die "$name: unknown style '$style'" ;;
    esac
}

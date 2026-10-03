# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# lib/fixlinks.sh - repair relative links after /bin, /sbin, /lib were merged
# into /usr. Example (util-linux):
#     usr/lib/libblkid.so -> ../../lib/libblkid.so.1.1.0
# points outside the package once the library moved to usr/lib. Every relative
# link that doesn't resolve inside $DEST is rewritten to the absolute path it
# meant on a merged-/usr system (here /usr/lib/libblkid.so.1.1.0).

_normpath() {
    local IFS=/ p
    local -a out=()
    for p in $1; do
        case "$p" in
            ''|.) ;;
            ..)   [ ${#out[@]} -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
            *)    out+=("$p") ;;
        esac
    done
    echo "/${out[*]}"
}

fix_links() {
    local l t rel abs
    while read -r l; do
        t=$(readlink "$l")
        case "$t" in /*) continue ;; esac
        [ -e "$l" ] && continue                    # resolves inside the package: fine
        rel=${l#"$DEST"}
        abs=$(_normpath "$(dirname "$rel")/$t")
        case "$abs" in
            /lib64/*)          abs="/usr/lib${abs#/lib64}" ;;
            /lib/*|/bin/*|/sbin/*) abs="/usr$abs" ;;
        esac
        if [ -e "$DEST$abs" ] || [ -L "$DEST$abs" ]; then
            ln -sfn "$abs" "$l"
            echo "fixed link: $rel -> $abs"
        fi
    done < <(find "$DEST" -type l)
}

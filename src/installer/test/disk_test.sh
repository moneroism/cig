#!/bin/bash
# disk_test.sh - run scenarios.txt through the shell installer's layout code
set -euo pipefail
cd "$(dirname "$0")"
sed -n '1,/^# ---------------- main/p' ../../../installer/cig-install | sed '/^umask 022$/d' > /tmp/.cig-layout-$$.sh
. /tmp/.cig-layout-$$.sh; rm -f /tmp/.cig-layout-$$.sh
pause() { :; }
DISK=sda
disk_geometry() { SECT=512; ALIGN=2048; FIRST=2048; LAST=209715166; }
blkid() { case "$1" in *1) echo "$1: TYPE=\"vfat\"" ;; *2) echo "$1: TYPE=\"ntfs\"" ;; *) echo "$1: TYPE=\"ext4\"" ;; esac; }
sfdisk() { case "$1" in -d) cat fixture.dump ;; *) cat >/dev/null ;; esac; }
while IFS='|' read -r name cmds; do
    case "$name" in \#*|"") continue ;; esac
    echo "== ${name%% *}"
    layout_clear; disk_geometry; WIPE=yes; HEADER=""
    IFS=';' read -r -a list <<< "$cmds"
    for c in "${list[@]}"; do
        read -r a b d e <<< "$c"
        case "$a" in
            auto)   SEP_HOME=$b ROOT_SIZE=$d SWAP_SIZE=$e; layout_auto ;;
            load)   layout_load ;;
            wipe)   layout_clear; disk_geometry; WIPE=yes; HEADER="" ;;
            mount)  [ "$d" = - ] && d=none; layout_ask_mount $((b - 1)) <<< "$d" >/dev/null ;;
            format) L_FORMAT[$((b - 1))]=$d ;;
            del)    layout_del $((b - 1)) ;;
            new)    parse_size "$d"; layout_new "$b" "$REPLY" ""
                    [ "$e" = - ] && e=none; layout_ask_mount $(( ${#L_KIND[@]} - 1 )) <<< "$e" >/dev/null ;;
        esac
    done
    echo "problems:"
    if out=$(layout_check); then
        layout_place   # layout_check placed in a subshell
        echo "table:"; table_script
    else
        printf '%s\n' "$out" | sed -n 's/^  \([^ ].*\)$/P \1/p'
    fi
done < scenarios.txt

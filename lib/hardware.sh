# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# lib/hardware.sh - what hardware is this build for?
# Recipes with hardware-dependent options ask here instead of hardcoding.
#
# Order of precedence:
#   1. CIG_GPUS="amd intel"            explicit choice (installer, user)
#   2. GPUS=... in /etc/cig/hardware.conf
#   3. CIG_PROFILE=generic             all common vendors (prebuilt packages)
#   4. detection from /sys             the machine we are building on

# GPU vendors: amd, intel, nvidia, vmware, virtio
cig_gpus() {
    if [ -n "${CIG_GPUS:-}" ]; then echo "$CIG_GPUS"; return; fi
    if [ -f /etc/cig/hardware.conf ]; then
        local GPUS=""
        # shellcheck disable=SC1091
        . /etc/cig/hardware.conf
        if [ -n "$GPUS" ]; then echo "$GPUS"; return; fi
    fi
    if [ "${CIG_PROFILE:-}" = generic ]; then echo "amd intel nvidia vmware virtio"; return; fi

    local d class vendor found=""
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/class" ] || continue
        class=$(cat "$d/class"); vendor=$(cat "$d/vendor")
        case "$class" in 0x03*) ;; *) continue ;; esac      # display controllers only
        case "$vendor" in
            0x1002) found="$found amd" ;;
            0x8086) found="$found intel" ;;
            0x10de) found="$found nvidia" ;;
            0x15ad) found="$found vmware" ;;
            0x1af4) found="$found virtio" ;;
        esac
    done
    echo "$found" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# has_gpu <vendor> -> exit 0 if this build targets that vendor
has_gpu() { case " $(cig_gpus) " in *" $1 "*) return 0 ;; esac; return 1; }

# feature <vendor> -> "enabled" / "disabled", for meson options
gpu_feature() { if has_gpu "$1"; then echo enabled; else echo disabled; fi; }

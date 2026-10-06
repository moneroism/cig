# wlroots (dwl, sway): render on the GPU only where Mesa has a driver for it (cig builds
# Mesa's RADV for amdgpu); otherwise the CPU renderer pixman, chosen before anything is
# tried. Without this, wlroots may start Mesa without a GPU driver: no speed-up, ~90 MB more
# memory, and warnings. Set WLR_RENDERER yourself to override.
if [ -z "${WLR_RENDERER:-}" ]; then
    _gpu=pixman
    for _n in /sys/class/drm/renderD*/device/driver; do
        case "$(basename "$(readlink "$_n" 2>/dev/null)")" in amdgpu) _gpu= ;; esac
    done
    [ -n "$_gpu" ] && export WLR_RENDERER=pixman
    unset _gpu _n
fi

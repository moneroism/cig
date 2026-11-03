# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# whence-index.awk <libre/firmware> <WHENCE> - one line per firmware file and link name:
#   <path> TAB free|non-free TAB <driver> TAB <why>
# A file is free when WHENCE gives it a free licence and its section names the source inside
# linux-firmware ("Source:"), or when libre/firmware lists it (source kept elsewhere). Anything
# else (binary only, "Redistributable", "Allegedly GPL, but no source visible") is non-free.
# In WHENCE a "Licence:" line covers the files listed before it in the same section; a link
# name is classed as its target.
BEGIN { OFS = "\t" }

FNR == NR {   # libre/firmware: <path> <where its source is>
    if ($0 ~ /^#/ || $0 ~ /^[ \t]*$/) next
    p = $0; sub(/[ \t].*/, "", p)
    w = $0; sub(/^[^ \t]+[ \t]+/, "", w)
    ext[p] = w
    next
}

function value(s) { sub(/^[A-Za-z]+:[ \t]*/, "", s); sub(/[ \t]+$/, "", s); return s }

function flush(   i, f, lic) {
    for (i = 1; i <= nf; i++) {
        f = files[i]; lic = (f in flic) ? flic[f] : last
        if (lic == "") lic = "unknown"
        if (f in ext)
            out[f] = "free" OFS drv OFS "source: " ext[f] "; " lic
        else if (src && lic ~ /GPL|BSD|MPL|MIT|[Ff]ree software/ && lic !~ /[Aa]llegedly|no source/)
            out[f] = "free" OFS drv OFS "source in linux-firmware; " lic
        else
            out[f] = "non-free" OFS drv OFS lic
    }
    nf = 0; np = 0; src = 0; drv = ""; last = ""
    split("", flic)
}

/^-----/ { flush(); next }
/^Driver:/ { drv = value($0); sub(/[ \t].*/, "", drv); next }
/^Source:/ { src = 1; next }
/^(File|RawFile):/ { f = value($0); gsub(/"/, "", f); files[++nf] = f; pend[++np] = f; next }
/^Licen[cs]e:/ {
    last = value($0)
    for (i = 1; i <= np; i++) flic[pend[i]] = last
    np = 0
    next
}
/^Link:/ {   # Link: <name> -> <target>, the target relative to the name's folder
    l = value($0); n = l; sub(/[ \t]*->.*/, "", n); t = l; sub(/.*->[ \t]*/, "", t)
    # string regexes: in BusyBox awk "[^\/]" also excludes the backslash of "a\ b" names
    if (index(n, "/")) { d = n; sub("/[^/]*$", "", d); t = d "/" t }
    while (t ~ "[^/]+/[.][.]/") sub("[^/]+/[.][.]/", "", t)
    links[n] = t
    next
}
END {
    flush()
    for (f in out) print f, out[f]
    for (n in links) {
        t = links[n]
        for (i = 0; i < 8 && !(t in out) && (t in links); i++) t = links[t]
        if (t in out) print n, out[t]
        else print n, "non-free", "", "link to " links[n] " (target not in WHENCE)"
    }
}

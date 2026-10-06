# assets

ASCII art and static texts, kept apart from the code that uses them.

| File | What | Used by |
|---|---|---|
| `logos/` | the logos, see below | `packages/fastfetch` (`/usr/share/fastfetch/logos/cig/`) |
| `live-issue.txt` | login banner of the install medium (`{VERSION}` is filled in, backslashes escaped) | `packages/cig-live` |
| `logo-designs.txt` | logo designs: the large braille logo (needs a Unicode font: graphical terminals, e.g. fastfetch), the "cig" lettering, the cigarette logo | (design source) |
| `live-banner-draft.txt` | the first banner draft | (design source) |

## Logos

Three sizes (a size is a maximum, lines x columns): **small** 6 x 20, **normal** 18 x 40,
**large** 30 x 60. The drawings are braille (graphical terminals); `cig-ascii.txt` is the plain
ASCII one for the Linux console. Colours are fastfetch placeholders, the same in every logo:

| | Part | 256-colour |
|---|---|---|
| `$1` | paper | 255 |
| `$2` | ember, flame | 202 |
| `$3` | smoke, ash | 245 |
| `$4` | filter | 180 |
| `$5` | charred | 240 |
| `$6` | flame core | 220 |

| File | Size | Drawing |
|---|---|---|
| `cig-small.txt` | small | the mascot: a hermit crab (minimal: carries only what it needs; hardened: lives in a hard shell; swaps it for a better one when it outgrows it) |
| `cig.txt` | normal | a cigarette being smoked (the default) |
| `cig-butt.txt` | normal | a butt stubbed out in the ashtray |
| `cig-ascii.txt` | normal | the cigarette in plain ASCII (console) |

Large (the cigarette just being lit) is still to be drawn.

The Linux console (where the live banner and the installer run) shows plain ASCII only:
at most 80 columns, and leave room for the login prompt below.

# assets

ASCII art and static texts, kept apart from the code that uses them.

| File | What | Used by |
|---|---|---|
| `live-issue.txt` | login banner of the install medium (`{VERSION}` is filled in, backslashes escaped) | `packages/cig-live` |
| `logo-designs.txt` | logo designs: the large braille logo (needs a Unicode font: graphical terminals, e.g. fastfetch), the "cig" lettering, the cigarette logo | (design source) |
| `live-banner-draft.txt` | the first banner draft | (design source) |

The Linux console (where the live banner and the installer run) shows plain ASCII only:
at most 80 columns, and leave room for the login prompt below.

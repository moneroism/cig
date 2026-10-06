/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/*
 * ui.h - the installer's screens, on ncurses: arrow keys move, Enter chooses,
 * Esc goes back, Space toggles in checklists.
 *
 * CIG_TUI_TRACE=<file>: after every key, the visible screen text is appended to
 * <file> (for testing without looking at the screen).
 */
#ifndef UI_H
#define UI_H

#include <stdbool.h>
#include <stddef.h>

void ui_init(void);
void ui_end(void);

/* a list to choose from; items may have a value shown on the right (NULL = none).
 * Returns the chosen index, or -1 for Esc. *sel is the start/last position. */
int ui_menu(const char *title, const char *text, const char *const *items,
            const char *const *values, int n, int *sel);

/* items with [x]/[ ]: Space toggles, Enter is done. */
void ui_checklist(const char *title, const char *text, const char *const *items, bool *on, int n);

/* a catalog: items under category headings, [x]/[ ] toggled with Space, "/" searches
 * (name, description and category; Enter keeps the filter, Esc clears it); Enter is done. */
void ui_catalog(const char *title, const char *text, const char *const *groups,
                const char *const *names, const char *const *descs, bool *on, int n);

/* a line of text; hidden for passwords. false on Esc (buf unchanged). */
bool ui_input(const char *title, const char *prompt, char *buf, size_t n, bool hidden);

bool ui_yesno(const char *title, const char *text, bool def);
void ui_msg(const char *title, const char *text);

/* a message shown while something short runs (no key needed; the next screen replaces it) */
void ui_wait(const char *title, const char *text);

/* a running job: a title and the last lines of its log, redrawn by the caller */
void ui_progress(const char *title, const char *step, const char *logfile);

#endif

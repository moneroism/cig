/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* ui.c - ncurses screens for the installer */
#include <curses.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ui.h"

#define KEY_ESC 27

static FILE *trace_f;

void ui_init(void)
{
	const char *t = getenv("CIG_TUI_TRACE");
	if (t && !(trace_f = fopen(t, "a")))
		perror(t);
	initscr();
	cbreak();
	noecho();
	keypad(stdscr, TRUE);
	set_escdelay(25);
	curs_set(0);
	if (has_colors()) {
		start_color();
		use_default_colors();
		init_pair(1, COLOR_BLACK, COLOR_CYAN);    /* selection */
		init_pair(2, COLOR_CYAN, -1);             /* titles, frames */
		init_pair(3, COLOR_RED, -1);              /* warnings */
	}
}

void ui_end(void)
{
	endwin();
	if (trace_f)
		fclose(trace_f);
}

/* the screen as text, after each key (CIG_TUI_TRACE) */
static void trace_screen(int key)
{
	char line[512];
	if (!trace_f)
		return;
	fprintf(trace_f, "---- key %d\n", key);
	for (int y = 0; y < LINES; y++) {
		mvinnstr(y, 0, line, COLS < 511 ? COLS : 511);
		size_t n = strlen(line);
		while (n && line[n - 1] == ' ')
			line[--n] = '\0';
		fprintf(trace_f, "%s\n", line);
	}
	fflush(trace_f);
}

static int key(void)
{
	int k = getch();
	if (k == '\r')
		k = '\n';
	return k;
}

/* frame and title; returns the first free row */
static int frame(const char *title)
{
	erase();
	attron(COLOR_PAIR(2) | A_BOLD);
	mvprintw(0, 1, "cig installer");
	attroff(A_BOLD);
	mvhline(1, 0, ACS_HLINE, COLS);
	attroff(COLOR_PAIR(2));
	attron(A_BOLD);
	mvprintw(2, 1, "%s", title);
	attroff(A_BOLD);
	return 4;
}

static void footer(const char *keys)
{
	attron(COLOR_PAIR(2));
	mvhline(LINES - 2, 0, ACS_HLINE, COLS);
	attroff(COLOR_PAIR(2));
	mvprintw(LINES - 1, 1, "%s", keys);
}

/* text with newlines, wrapped at the screen width; returns the next row */
static int text_block(int y, const char *text)
{
	const char *p = text;
	int w = COLS - 3;
	while (p && *p && y < LINES - 3) {
		int len = (int)strcspn(p, "\n");
		if (len > w) {   /* wrap at the last space */
			int cut = w;
			while (cut > 0 && p[cut] != ' ')
				cut--;
			len = cut > 0 ? cut : w;
		}
		mvprintw(y++, 2, "%.*s", len, p);
		p += len;
		if (*p == '\n' || *p == ' ')
			p++;
	}
	return y;
}

int ui_menu(const char *title, const char *text, const char *const *items,
            const char *const *values, int n, int *sel)
{
	int cur = sel && *sel >= 0 && *sel < n ? *sel : 0, top = 0;
	for (;;) {
		int y = frame(title), k, rows, wname = 0;
		if (text)
			y = text_block(y, text) + 1;
		rows = LINES - 3 - y;
		if (rows < 1)
			rows = 1;
		for (int i = 0; i < n; i++)
			if ((int)strlen(items[i]) > wname)
				wname = (int)strlen(items[i]);
		if (cur < top)
			top = cur;
		if (cur >= top + rows)
			top = cur - rows + 1;
		for (int i = top; i < n && i < top + rows; i++) {
			if (i == cur)
				attron(COLOR_PAIR(1) | A_BOLD);
			mvprintw(y + i - top, 2, " %-*s ", wname, items[i]);
			if (values && values[i])
				printw(" %.*s", COLS - wname - 8 > 0 ? COLS - wname - 8 : 0, values[i]);
			if (i == cur)
				attroff(COLOR_PAIR(1) | A_BOLD);
		}
		footer("Up/Down move   Enter choose   Esc back");
		refresh();
		k = key();
		switch (k) {
		case KEY_UP: case 'k': cur = cur > 0 ? cur - 1 : n - 1; break;
		case KEY_DOWN: case 'j': cur = cur < n - 1 ? cur + 1 : 0; break;
		case KEY_HOME: cur = 0; break;
		case KEY_END: cur = n - 1; break;
		case KEY_PPAGE: cur = cur > rows ? cur - rows : 0; break;
		case KEY_NPAGE: cur = cur + rows < n ? cur + rows : n - 1; break;
		case '\n':
			if (sel)
				*sel = cur;
			trace_screen(k);
			return cur;
		case KEY_ESC: case 'q':
			trace_screen(k);
			return -1;
		}
		trace_screen(k);
	}
}

void ui_checklist(const char *title, const char *text, const char *const *items, bool *on, int n)
{
	int cur = 0, top = 0;
	for (;;) {
		int y = frame(title), rows, k;
		if (text)
			y = text_block(y, text) + 1;
		rows = LINES - 3 - y;
		if (rows < 1)
			rows = 1;
		if (cur < top)
			top = cur;
		if (cur >= top + rows)
			top = cur - rows + 1;
		for (int i = top; i < n && i < top + rows; i++) {
			if (i == cur)
				attron(COLOR_PAIR(1) | A_BOLD);
			mvprintw(y + i - top, 2, " [%c] %-*.*s ", on[i] ? 'x' : ' ', COLS - 12, COLS - 12, items[i]);
			if (i == cur)
				attroff(COLOR_PAIR(1) | A_BOLD);
		}
		footer("Up/Down move   Space toggle   Enter done");
		refresh();
		k = key();
		switch (k) {
		case KEY_UP: case 'k': cur = cur > 0 ? cur - 1 : n - 1; break;
		case KEY_DOWN: case 'j': cur = cur < n - 1 ? cur + 1 : 0; break;
		case ' ': on[cur] = !on[cur]; break;
		case '\n': case KEY_ESC:
			trace_screen(k);
			return;
		}
		trace_screen(k);
	}
}

/* case-insensitive: does s contain the (lowercase) needle? */
static bool has_text(const char *s, const char *needle)
{
	size_t nl = strlen(needle);
	for (; *s; s++) {
		size_t i = 0;
		while (i < nl && s[i] && (s[i] | 0x20) == needle[i])
			i++;
		if (i == nl)
			return true;
	}
	return !nl;
}

void ui_catalog(const char *title, const char *text, const char *const *groups,
                const char *const *names, const char *const *descs, bool *on, int n)
{
	char filter[48] = "";
	bool typing = false;
	int sel = 0, top = 0, wname = 0;
	int *rows = malloc(((size_t)n * 2 + 1) * sizeof(int));   /* >= 0 an item, < 0 a heading */
	if (!rows)
		exit(1);
	for (int i = 0; i < n; i++)
		if ((int)strlen(names[i]) > wname)
			wname = (int)strlen(names[i]);
	for (;;) {
		/* the visible rows: matching items, a heading wherever the category changes */
		int nr = 0, pos = -1, k;
		const char *last = NULL;
		for (int i = 0; i < n; i++) {
			if (!has_text(names[i], filter) && !has_text(descs[i], filter) && !has_text(groups[i], filter))
				continue;
			if (!last || strcmp(last, groups[i]))
				rows[nr++] = -1 - i;
			last = groups[i];
			if (i == sel)
				pos = nr;
			rows[nr++] = i;
		}
		if (pos < 0)   /* the selection was filtered out: the first match */
			for (int r = 0; r < nr && pos < 0; r++)
				if (rows[r] >= 0) {
					pos = r;
					sel = rows[r];
				}

		int y = frame(title), height;
		if (text)
			y = text_block(y, text) + 1;
		if (typing || *filter) {
			mvprintw(y, 2, "Search: %s%s", filter, typing ? "_" : "");
			y += 2;
		}
		height = LINES - 3 - y;
		if (height < 1)
			height = 1;
		if (pos >= 0 && pos - 1 < top)   /* keep the item's heading in view when possible */
			top = pos > 0 && rows[pos - 1] < 0 ? pos - 1 : pos;
		if (pos >= top + height)
			top = pos - height + 1;
		if (nr == 0)
			mvprintw(y, 2, "(nothing matches \"%s\")", filter);
		for (int r = top; r < nr && r < top + height; r++) {
			if (rows[r] < 0) {
				attron(COLOR_PAIR(2) | A_BOLD);
				mvprintw(y + r - top, 2, "%s", groups[-1 - rows[r]]);
				attroff(COLOR_PAIR(2) | A_BOLD);
				continue;
			}
			int i = rows[r], w = COLS - wname - 14;
			if (r == pos)
				attron(COLOR_PAIR(1) | A_BOLD);
			mvprintw(y + r - top, 3, " [%c] %-*s  %-*.*s", on[i] ? 'x' : ' ', wname, names[i],
			         w > 0 ? w : 0, w > 0 ? w : 0, descs[i]);
			if (r == pos)
				attroff(COLOR_PAIR(1) | A_BOLD);
		}
		footer(typing ? "Type to search   Enter keep   Esc clear"
		              : "Up/Down move   Space toggle   / search   Enter done");
		refresh();
		k = key();
		if (typing) {
			size_t len = strlen(filter);
			if (k == '\n') {
				typing = false;
			} else if (k == KEY_ESC) {
				typing = false;
				filter[0] = '\0';
			} else if ((k == KEY_BACKSPACE || k == 127 || k == 8) && len) {
				filter[len - 1] = '\0';
			} else if (k >= 32 && k < 127 && len + 1 < sizeof(filter)) {
				filter[len] = (char)(k >= 'A' && k <= 'Z' ? k + 32 : k);
				filter[len + 1] = '\0';
			}
			trace_screen(k);
			continue;
		}
		int step = 0;
		switch (k) {
		case KEY_UP: case 'k': step = -1; break;
		case KEY_DOWN: case 'j': step = 1; break;
		case KEY_PPAGE: step = -height; break;
		case KEY_NPAGE: step = height; break;
		case ' ':
			if (pos >= 0)
				on[sel] = !on[sel];
			break;
		case '/':
			typing = true;
			break;
		case KEY_ESC:
			if (*filter) {
				filter[0] = '\0';
				break;
			}
			/* fall through */
		case '\n':
			trace_screen(k);
			free(rows);
			return;
		}
		/* move over items, skipping headings; stop at the ends */
		for (int r = pos, left = step < 0 ? -step : step; step && pos >= 0 && left > 0; ) {
			r += step < 0 ? -1 : 1;
			if (r < 0 || r >= nr)
				break;
			if (rows[r] >= 0) {
				sel = rows[r];
				left--;
			}
		}
		trace_screen(k);
	}
}

bool ui_input(const char *title, const char *prompt, char *buf, size_t n, bool hidden)
{
	char *edit = calloc(n, 1);
	size_t len;
	if (!edit)
		return false;
	snprintf(edit, n, "%s", hidden ? "" : buf);
	len = strlen(edit);
	curs_set(1);
	for (;;) {
		int y = frame(title), k;
		y = text_block(y, prompt) + 1;
		mvprintw(y, 2, "> ");
		for (size_t i = 0; i < len; i++)
			addch(hidden ? '*' : (unsigned char)edit[i]);
		footer("Enter accept   Esc cancel");
		move(y, 4 + (int)len);
		refresh();
		k = key();
		trace_screen(k);
		if (k == '\n') {
			snprintf(buf, n, "%s", edit);
			break;
		}
		if (k == KEY_ESC) {
			free(edit);
			curs_set(0);
			return false;
		}
		if ((k == KEY_BACKSPACE || k == 127 || k == 8) && len)
			edit[--len] = '\0';
		else if (k >= 32 && k < 127 && len + 1 < n)
			edit[len++] = (char)k, edit[len] = '\0';
	}
	memset(edit, 0, n);   /* passwords: don't leave copies around */
	free(edit);
	curs_set(0);
	return true;
}

bool ui_yesno(const char *title, const char *text, bool def)
{
	static const char *const items[] = { "Yes", "No" };
	int sel = def ? 0 : 1;
	return ui_menu(title, text, items, NULL, 2, &sel) == 0;
}

void ui_msg(const char *title, const char *text)
{
	int k;
	frame(title);
	text_block(4, text);
	footer("Enter continue");
	refresh();
	do {
		k = key();
		trace_screen(k);
	} while (k != '\n' && k != KEY_ESC);
}

void ui_progress(const char *title, const char *step, const char *logfile)
{
	char lines[64][256];
	int n = 0, y = frame(title), rows;
	FILE *f = logfile ? fopen(logfile, "r") : NULL;
	attron(A_BOLD);
	mvprintw(y++, 2, "==> %s", step);
	attroff(A_BOLD);
	y++;
	rows = LINES - 3 - y;
	if (rows > 64)
		rows = 64;
	while (f && rows > 0 && fgets(lines[n % rows], sizeof(lines[0]), f))
		n++;
	if (f)
		fclose(f);
	for (int i = n > rows ? n - rows : 0; i < n; i++) {
		char *l = lines[i % rows];
		l[strcspn(l, "\n")] = '\0';
		mvprintw(y++, 2, "%.*s", COLS - 4, l);
	}
	footer("installing - this can take hours when compiling");
	refresh();
}

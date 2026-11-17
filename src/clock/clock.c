/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/*
 * clock - the time in large digits that fill the terminal, the date below.
 *
 * Nothing but libc. The digits are spaces in reverse video (or on a background
 * colour): no font has to carry block characters, so the Linux console shows the
 * same picture as a graphical terminal. The terminal is restored on every exit,
 * Ctrl+C included.
 *
 *   keys: a 12/24 hours   s seconds   d date   c colour   q quit
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static struct termios saved;
static volatile sig_atomic_t stop, resized;
static int rows = 24, cols = 80;
static int twelve, seconds = 1, date = 1, colour;   /* colour 0: the terminal's own (reverse video) */

/* ---------------- the screen: one buffer, written once per picture ---------------- */

static char *out;
static size_t outlen, outcap;

static void putn(const char *s, size_t n)
{
	if (outlen + n > outcap) {
		outcap = (outlen + n) * 2;
		if (!(out = realloc(out, outcap)))
			exit(1);
	}
	memcpy(out + outlen, s, n);
	outlen += n;
}

static void put(const char *s)
{
	putn(s, strlen(s));
}

static void spaces(int n)
{
	while (n-- > 0)
		putn(" ", 1);
}

static void flush_out(void)
{
	for (size_t off = 0; off < outlen; ) {
		ssize_t w = write(1, out + off, outlen - off);
		if (w < 0 && errno != EINTR)
			break;
		if (w > 0)
			off += (size_t)w;
	}
	outlen = 0;
}

static void size_screen(void)
{
	struct winsize ws;
	if (ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_row && ws.ws_col) {
		rows = ws.ws_row;
		cols = ws.ws_col;
	}
}

/* ---------------- the digits ---------------- */

/* 3 cells wide, 5 high: one octal digit per row, top row first */
static const unsigned short font[10] = {
	075557, 026227, 071747, 071717, 055711, 074717, 074757, 071111, 075757, 075717,
};

/* row r of the face ("12:34:56", "1:05") as cells, 1 = lit: a digit is 3 wide, the colon 1,
 * one dark cell between them. Returns the width (27 at most) */
static int face_row(const char *face, int r, char *cells)
{
	int w = 0;
	for (const char *p = face; *p; p++) {
		if (p != face)
			cells[w++] = 0;
		if (*p == ':')
			cells[w++] = r == 1 || r == 3;
		else
			for (int c = 0; c < 3; c++)
				cells[w++] = font[*p - '0'] >> ((4 - r) * 3 + (2 - c)) & 1;
	}
	return w;
}

/* a line of plain text in the middle of the row; returns the columns used */
static int centred(const char *s)
{
	int n = (int)strlen(s);
	if (n > cols)
		n = cols;
	spaces((cols - n) / 2);
	putn(s, (size_t)n);
	return (cols - n) / 2 + n;
}

static void draw(const struct tm *tm)
{
	char face[16], text[80], cells[32], on[16];
	int hour = tm->tm_hour, w, k, sx, sy, gap, left, top;
	size_t n;

	if (twelve)
		hour = hour % 12 ? hour % 12 : 12;
	n = (size_t)snprintf(face, sizeof(face), twelve ? "%d:%02d" : "%02d:%02d", hour % 100, tm->tm_min % 100);
	if (seconds && n < sizeof(face))
		snprintf(face + n, sizeof(face) - n, ":%02d", tm->tm_sec % 100);
	n = date ? strftime(text, sizeof(text) - 4, "%A, %d %B %Y", tm) : 0;
	text[n] = '\0';
	if (twelve)
		snprintf(text + n, sizeof(text) - n, "%s%s", n ? "  " : "", tm->tm_hour < 12 ? "AM" : "PM");

	/* the largest cell (2k columns by k rows, about square) that leaves room for the text
	 * line; a small window loses the text first, then the digits become one column per cell,
	 * and below that the time is written as plain text */
	w = face_row(face, 0, cells);
	gap = text[0] && rows >= 7 ? 1 : 0;     /* empty rows between the digits and the text */
	k = (cols - 2) / (2 * w);
	if (k > (rows - 2 * gap) / 5)
		k = (rows - 2 * gap) / 5;
	sx = k > 0 ? 2 * k : 1;
	sy = k > 0 ? k : 1;
	if (cols < w || rows < 5)
		sy = gap = 0;                   /* no digits: the face as text */
	if (gap && sy / 2 > gap)                /* large digits: the text keeps its distance */
		gap = sy / 2 < rows - 5 * sy - 1 ? sy / 2 : rows - 5 * sy - 1;
	left = (cols - w * sx) / 2;
	top = (rows - 5 * sy - (gap ? gap + 1 : 0)) / 2;
	if (colour)
		snprintf(on, sizeof(on), "\033[4%dm", colour);
	else
		snprintf(on, sizeof(on), "\033[7m");

	put("\033[H");
	for (int y = 0; y < rows; y++) {
		int r = y - top, used = 0;
		if (sy && r >= 0 && r < 5 * sy) {
			int lit = 0;
			face_row(face, r / sy, cells);
			spaces(left);
			for (int c = 0; c < w; c++) {
				if (cells[c] != lit) {
					lit = cells[c];
					put(lit ? on : "\033[0m");
				}
				spaces(sx);
			}
			if (lit)
				put("\033[0m");
			used = left + w * sx;
		} else if (gap && r == 5 * sy + gap) {
			used = centred(text);
		} else if (!sy && y == rows / 2) {
			used = centred(face);
		}
		if (used < cols)                /* in a full row this would erase its last cell */
			put("\033[K");
		if (y < rows - 1)
			put("\r\n");
	}
	flush_out();
}

/* ---------------- the terminal ---------------- */

static void restore(void)
{
	tcsetattr(0, TCSANOW, &saved);
	put("\033[0m\033[2J\033[H\033[?25h\033[?1049l");
	flush_out();
}

static void on_signal(int sig)
{
	if (sig == SIGWINCH)
		resized = 1;
	else
		stop = 1;
}

static void setup(void)
{
	struct termios raw;
	struct sigaction sa = { 0 };
	if (tcgetattr(0, &saved) != 0) {
		fputs("clock: not a terminal\n", stderr);
		exit(1);
	}
	raw = saved;
	raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
	raw.c_cc[VMIN] = 0;
	raw.c_cc[VTIME] = 0;
	tcsetattr(0, TCSANOW, &raw);
	atexit(restore);
	sa.sa_handler = on_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	sigaction(SIGWINCH, &sa, NULL);
	put("\033[?1049h\033[?25l\033[2J");
	flush_out();
	size_screen();
}

int main(int argc, char **argv)
{
	int opt, redraw = 1;
	long shown = -1;
	while ((opt = getopt(argc, argv, "asdc:")) != -1) {
		if (opt == 'a')
			twelve = 1;
		else if (opt == 's')
			seconds = 0;
		else if (opt == 'd')
			date = 0;
		else if (opt == 'c' && optarg[0] >= '0' && optarg[0] <= '7' && !optarg[1])
			colour = optarg[0] - '0';
		else
			optind = argc + 1;
	}
	if (optind != argc) {
		fputs("usage: clock [-a] [-s] [-d] [-c 0-7]\n"
		      "  -a  12 hours with AM/PM\n"
		      "  -s  no seconds\n"
		      "  -d  no date\n"
		      "  -c  colour of the digits: 0 the terminal's own (default), 1 red, 2 green,\n"
		      "      3 yellow, 4 blue, 5 magenta, 6 cyan, 7 white\n"
		      "  keys: a 12/24 hours, s seconds, d date, c colour, q quit\n", stderr);
		return 1;
	}
	tzset();
	setup();
	while (!stop) {
		struct pollfd in = { 0, POLLIN, 0 };
		struct timespec now;
		struct tm tm;
		long stamp;
		char k;
		if (resized) {
			resized = 0;
			size_screen();
			redraw = 1;
		}
		clock_gettime(CLOCK_REALTIME, &now);
		if (!localtime_r(&now.tv_sec, &tm))
			break;
		/* what the picture shows, as one number: drawn again only when it changes */
		stamp = ((tm.tm_yday * 24L + tm.tm_hour) * 60 + tm.tm_min) * 60 + (seconds ? tm.tm_sec : 0);
		if (redraw || stamp != shown) {
			draw(&tm);
			shown = stamp;
			redraw = 0;
		}
		/* until the next second begins, a key arrives or a signal interrupts */
		if (poll(&in, 1, 1001 - (int)(now.tv_nsec / 1000000)) <= 0)
			continue;
		if (read(0, &k, 1) != 1)
			break;                          /* the terminal is gone */
		do {
			switch (k) {
			case 'q': case 'Q': case 27: stop = 1; break;
			case 'a': twelve = !twelve; break;
			case 's': seconds = !seconds; break;
			case 'd': date = !date; break;
			case 'c': colour = (colour + 1) % 8; break;
			}
		} while (read(0, &k, 1) == 1);
		redraw = 1;
	}
	return 0;
}

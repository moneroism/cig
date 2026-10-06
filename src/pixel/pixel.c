/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/*
 * pixel - small terminal animations: rain, stars, smoke.
 *
 * ASCII and the 8 basic colours by default, so it runs on the Linux console;
 * -u uses Unicode glyphs (graphical terminals). The terminal is restored on
 * every exit, Ctrl+C included.
 *
 *   keys: 1 rain  2 stars  3 smoke   + - speed   c colour   p pause   q quit
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
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
static unsigned long long rng = 0x9e3779b97f4a7c15ULL;

static unsigned rnd(unsigned n)   /* xorshift64*, 0 .. n-1 */
{
	rng ^= rng >> 12;
	rng ^= rng << 25;
	rng ^= rng >> 27;
	return n ? (unsigned)((rng * 2685821657736338717ULL) >> 33) % n : 0;
}

/* ---------------- the screen: one buffer, written once per frame ---------------- */

static char *out;
static size_t outlen, outcap;

static void put(const char *s)
{
	size_t n = strlen(s);
	if (outlen + n > outcap) {
		outcap = (outlen + n) * 2;
		if (!(out = realloc(out, outcap)))
			exit(1);
	}
	memcpy(out + outlen, s, n);
	outlen += n;
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

/* a cell: glyph and colour (0 = empty) */
struct cell {
	const char *g;
	int color, bold;
};
static struct cell *grid;

static void size_screen(void)
{
	struct winsize ws;
	if (ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_row && ws.ws_col) {
		rows = ws.ws_row;
		cols = ws.ws_col;
	}
	free(grid);
	if (!(grid = calloc((size_t)rows * (size_t)cols, sizeof(*grid))))
		exit(1);
}

static void draw(void)
{
	char seq[32];
	int last = -1, lastbold = -1;
	put("\033[H");
	for (int y = 0; y < rows; y++) {
		for (int x = 0; x < cols; x++) {
			struct cell *c = &grid[y * cols + x];
			if (!c->g) {
				put(" ");
				continue;
			}
			if (c->color != last || c->bold != lastbold) {
				snprintf(seq, sizeof(seq), "\033[%d;%dm", c->bold ? 1 : 22, 30 + c->color);
				put(seq);
				last = c->color;
				lastbold = c->bold;
			}
			put(c->g);
		}
		if (y < rows - 1)
			put("\r\n");
	}
	put("\033[0m");
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
		fputs("pixel: not a terminal\n", stderr);
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

/* ---------------- the effects ---------------- */

static const char *const ascii_rain[] = { "0", "1", "|", "/", "\\", "*", "+", "=", "<", ">", "$", "#", "%", "&", "@", "?" };
static const char *const uni_rain[] = { "ｱ", "ｲ", "ｳ", "ｴ", "ｵ", "ｶ", "ｷ", "ｸ", "ｹ", "ｺ", "0", "1", "ﾊ", "ﾋ", "ﾌ", "ﾍ" };
static const char *const ascii_star[] = { ".", "+", "*" };
static const char *const uni_star[] = { "·", "✦", "★" };
static const char *const ascii_smoke[] = { ".", "o", "O", "0" };
static const char *const uni_smoke[] = { "░", "▒", "▓", "█" };

static int unicode, color = 2, mode = 1;   /* colour: 1 red .. 7 white; green first */

/* rain: one falling head per column, with a fading trail */
static int *head, *trail;

static void rain_step(void)
{
	const char *const *g = unicode ? uni_rain : ascii_rain;
	for (int x = 0; x < cols; x++) {
		if (head[x] < 0) {
			if (rnd(40) == 0) {   /* a new drop */
				head[x] = 0;
				trail[x] = 4 + (int)rnd((unsigned)rows / 2 + 1);
			}
			continue;
		}
		for (int y = 0; y < rows; y++) {   /* fade what is above the trail */
			struct cell *c = &grid[y * cols + x];
			if (y < head[x] - trail[x])
				c->g = NULL;
			else if (c->g)
				c->bold = 0, c->color = color;
		}
		if (head[x] < rows)
			grid[head[x] * cols + x] = (struct cell){ g[rnd(16)], 7, 1 };   /* the bright head */
		if (rnd(8) == 0 && head[x] > 0)   /* glyphs in the trail change now and then */
			grid[(int)rnd((unsigned)head[x]) * cols + x].g = g[rnd(16)];
		if (++head[x] - trail[x] > rows)
			head[x] = -1;
	}
}

/* stars: points flying outward from the centre, faster and brighter as they come close */
struct star {
	float x, y, z;
};
static struct star stars[256];

static void star_reset(struct star *s)
{
	s->x = (float)rnd(2000) / 1000.0f - 1.0f;
	s->y = (float)rnd(2000) / 1000.0f - 1.0f;
	s->z = 1.0f;
}

static void stars_step(void)
{
	const char *const *g = unicode ? uni_star : ascii_star;
	memset(grid, 0, (size_t)rows * (size_t)cols * sizeof(*grid));
	for (int i = 0; i < 256; i++) {
		struct star *s = &stars[i];
		s->z -= 0.012f;
		int x = cols / 2 + (int)(s->x / s->z * (float)cols / 2);
		int y = rows / 2 + (int)(s->y / s->z * (float)rows / 2);
		if (s->z <= 0.05f || x < 0 || x >= cols || y < 0 || y >= rows) {
			star_reset(s);
			continue;
		}
		int b = s->z > 0.6f ? 0 : s->z > 0.3f ? 1 : 2;
		grid[y * cols + x] = (struct cell){ g[b], b == 2 ? 7 : color, b == 2 };
	}
}

/* smoke: puffs rising from a point near the bottom, drifting and thinning out */
struct puff {
	float x, y, dx;
	int age, life;
};
static struct puff puffs[400];

static void smoke_step(void)
{
	const char *const *g = unicode ? uni_smoke : ascii_smoke;
	memset(grid, 0, (size_t)rows * (size_t)cols * sizeof(*grid));
	for (int i = 0; i < 400; i++) {
		struct puff *p = &puffs[i];
		if (p->age >= p->life) {   /* a new puff from the source */
			if (rnd(6))
				continue;
			p->x = (float)cols / 2 + (float)rnd(3) - 1;
			p->y = (float)rows - 2;
			p->dx = ((float)rnd(100) - 50.0f) / 400.0f;
			p->age = 0;
			p->life = rows + (int)rnd((unsigned)rows);
		}
		p->age++;
		p->y -= 0.5f;
		p->dx += ((float)rnd(100) - 50.0f) / 2000.0f;   /* drift */
		p->x += p->dx;
		int x = (int)p->x, y = (int)p->y;
		if (x < 0 || x >= cols || y < 0) {
			p->age = p->life;
			continue;
		}
		int d = 3 - p->age * 4 / p->life;   /* dense at the start, thin at the end */
		grid[y * cols + x] = (struct cell){ g[d < 0 ? 0 : d], color, d >= 3 };
	}
}

static void reset_effect(void)
{
	free(head);
	free(trail);
	if (!(head = malloc((size_t)cols * sizeof(int))) || !(trail = malloc((size_t)cols * sizeof(int))))
		exit(1);
	for (int x = 0; x < cols; x++)
		head[x] = -1 - (int)rnd((unsigned)rows);
	for (int i = 0; i < 256; i++) {
		star_reset(&stars[i]);
		stars[i].z = (float)(rnd(950) + 50) / 1000.0f;
	}
	for (int i = 0; i < 400; i++)
		puffs[i].age = puffs[i].life = 0;
	memset(grid, 0, (size_t)rows * (size_t)cols * sizeof(*grid));
}

int main(int argc, char **argv)
{
	int delay = 50;   /* milliseconds per frame */
	int paused = 0, opt;
	while ((opt = getopt(argc, argv, "um:")) != -1) {
		if (opt == 'u')
			unicode = 1;
		else if (opt == 'm' && optarg[0] >= '1' && optarg[0] <= '3' && !optarg[1])
			mode = optarg[0] - '0';
		else {
			fputs("usage: pixel [-u] [-m 1|2|3]\n"
			      "  -u  Unicode glyphs (graphical terminals)   -m  1 rain, 2 stars, 3 smoke\n"
			      "  keys: 1 2 3 effect, + - speed, c colour, p pause, q quit\n", stderr);
			return 1;
		}
	}
	rng ^= (unsigned long long)time(NULL) * 0x2545f4914f6cdd1dULL;
	setup();
	reset_effect();
	while (!stop) {
		char k;
		while (read(0, &k, 1) == 1) {
			switch (k) {
			case 'q': case 'Q': case 27: stop = 1; break;
			case '1': case '2': case '3': mode = k - '0'; reset_effect(); break;
			case '+': case '=': if (delay > 10) delay -= 10; break;
			case '-': case '_': if (delay < 300) delay += 10; break;
			case 'c': color = color % 7 + 1; break;
			case 'p': paused = !paused; break;
			}
		}
		if (resized) {
			resized = 0;
			size_screen();
			reset_effect();
			put("\033[2J");
		}
		if (!paused) {
			if (mode == 1)
				rain_step();
			else if (mode == 2)
				stars_step();
			else
				smoke_step();
			draw();
		}
		struct timespec ts = { 0, delay * 1000000L };
		nanosleep(&ts, NULL);
	}
	return 0;
}

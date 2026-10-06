/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/*
 * pixel - small terminal animations: plasma, tunnel, a self-steering fractal zoom, stars.
 *
 * ASCII and the 8 basic colours by default, so it runs on the Linux console;
 * -u uses Unicode shading blocks and 256 colours (graphical terminals). The
 * terminal is restored on every exit, Ctrl+C included.
 *
 *   keys: 1 plasma  2 tunnel  3 fractal  4 stars   + - speed   c colours   p pause   q quit
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <math.h>
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

/* a cell: glyph and colour (basic: 1..7 with bold; -u: 16..255 of the 256 colours) */
struct cell {
	const char *g;
	int color, bold;
};
static struct cell *grid;
static int unicode;

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
				if (unicode)
					snprintf(seq, sizeof(seq), "\033[38;5;%dm", c->color);
				else
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

/* ---------------- shading and colour ---------------- */

static const char *const ascii_ramp[] = { " ", ".", ",", ":", ";", "-", "=", "+", "*", "#", "%", "@" };
static const char *const uni_ramp[] = { " ", "░", "▒", "▓", "█" };
static int palette;   /* the c key */

/* set a cell from a brightness and a hue, both 0..1 */
static void shade(struct cell *c, double v, double hue)
{
	if (v < 0)
		v = 0;
	if (v > 0.999)
		v = 0.999;
	hue -= floor(hue);
	if (unicode) {
		c->g = uni_ramp[(int)(v * 5)];
		/* a smooth walk through the 6x6x6 colour cube, shifted by the palette */
		double h = (hue + palette * 0.17) * 6.2831853;
		int r = (int)((sin(h) * 0.5 + 0.5) * 5.99);
		int g = (int)((sin(h + 2.094) * 0.5 + 0.5) * 5.99);
		int b = (int)((sin(h + 4.189) * 0.5 + 0.5) * 5.99);
		c->color = 16 + 36 * r + 6 * g + b;
		c->bold = 0;
	} else {
		static const int sets[4][6] = {
			{ 4, 6, 2, 3, 1, 5 }, { 1, 3, 7, 3, 1, 5 }, { 2, 6, 2, 3, 2, 6 }, { 5, 4, 6, 4, 5, 1 },
		};
		c->g = ascii_ramp[(int)(v * 12)];
		c->color = sets[palette % 4][(int)(hue * 6)];
		c->bold = v > 0.6;
	}
	if (v < 0.04)
		c->g = NULL;
}

/* ---------------- the effects ---------------- */

static double t;   /* animation time */

/* plasma: overlapping sine fields */
static void plasma_step(void)
{
	double cx = cols / 2.0 + cols / 4.0 * sin(t * 0.37), cy = rows + rows / 2.0 * cos(t * 0.29);
	for (int y = 0; y < rows; y++)
		for (int x = 0; x < cols; x++) {
			double px = x, py = y * 2.0;   /* character cells are about twice as tall as wide */
			double v = sin(px * 0.07 + t) + sin(py * 0.05 + t * 1.3) + sin((px + py) * 0.04 + t * 0.7) +
			           sin(hypot(px - cx, py - cy) * 0.09 - t);
			double n = (v + 4.0) / 8.0;
			shade(&grid[y * cols + x], 0.25 + 0.75 * n, n + t * 0.03);
		}
}

/* tunnel: a checkered tube, looked into from its end */
static void tunnel_step(void)
{
	double cx = cols / 2.0 + cols / 8.0 * sin(t * 0.5), cy = rows + rows / 4.0 * sin(t * 0.4);
	for (int y = 0; y < rows; y++)
		for (int x = 0; x < cols; x++) {
			double dx = x - cx, dy = y * 2.0 - cy;
			double d = sqrt(dx * dx + dy * dy) + 0.5;
			double depth = 40.0 / d + t * 1.5, around = atan2(dy, dx) / 3.14159265 * 4.0 + t * 0.3;
			int check = ((int)floor(depth) ^ (int)floor(around)) & 1;
			double fog = d / (cols * 0.55);   /* the far end is dark */
			if (fog > 1)
				fog = 1;
			shade(&grid[y * cols + x], (check ? 0.85 : 0.35) * fog, depth * 0.05);
		}
}

/* fractal: zooms into the Mandelbrot set's edge; when the view runs out of detail (or of
 * floating-point precision) it steers to the busiest edge in view, or starts over elsewhere */
static double fx = -0.743643887037151, fy = 0.131825904205330, fscale = 3.0;
static int *iters;

static void fractal_retarget(int maxit)
{
	static const double spots[][2] = {
		{ -0.743643887037151, 0.131825904205330 }, { -0.7453, 0.1127 }, { 0.2501, 0.0000016 },
		{ -1.25066, 0.02012 }, { -0.16070135, 1.0375665 }, { 0.360240443437, -0.641313061064 },
	};
	int best = -1, bestscore = 0;
	for (int y = 1; y < rows - 1; y++)   /* the busiest edge: iteration counts differ most */
		for (int x = 1; x < cols - 1; x++) {
			int i = iters[y * cols + x];
			if (i >= maxit)
				continue;
			int s = abs(i - iters[y * cols + x - 1]) + abs(i - iters[y * cols + x + 1]) +
			        abs(i - iters[(y - 1) * cols + x]) + abs(i - iters[(y + 1) * cols + x]);
			s -= (abs(x - cols / 2) + abs(y - rows / 2) * 2) / 4;   /* prefer the middle */
			if (s > bestscore) {
				bestscore = s;
				best = y * cols + x;
			}
		}
	if (best >= 0 && fscale > 1e-12) {
		fx += ((best % cols) - cols / 2.0) * fscale / cols;
		fy += ((best / cols) - rows / 2.0) * 2.0 * fscale / cols;
	} else {   /* nothing left to see, or at the end of double precision: somewhere new */
		int s = (int)rnd(sizeof(spots) / sizeof(*spots));
		fx = spots[s][0];
		fy = spots[s][1];
		fscale = 3.0;
	}
}

static void fractal_step(void)
{
	static int frame;
	int maxit = 48 + (int)(28.0 * log2(3.0 / fscale)), edges = 0;
	if (maxit > 2000)
		maxit = 2000;
	for (int y = 0; y < rows; y++)
		for (int x = 0; x < cols; x++) {
			double cr = fx + (x - cols / 2.0) * fscale / cols, ci = fy + (y - rows / 2.0) * 2.0 * fscale / cols;
			double zr = 0, zi = 0, zr2 = 0, zi2 = 0;
			int i = 0;
			while (i < maxit && zr2 + zi2 < 4.0) {
				zi = 2 * zr * zi + ci;
				zr = zr2 - zi2 + cr;
				zr2 = zr * zr;
				zi2 = zi * zi;
				i++;
			}
			iters[y * cols + x] = i;
			if (x && i != iters[y * cols + x - 1])
				edges++;
			if (i >= maxit)
				grid[y * cols + x].g = NULL;   /* inside the set */
			else
				shade(&grid[y * cols + x], 0.3 + 0.7 * fmod(i / 24.0, 1.0), i / 64.0);
		}
	fscale *= 0.965;
	/* steer: too little edge in view, or every 40 frames towards the busiest edge */
	if (edges < rows * cols / 40 || fscale < 1e-12 || ++frame % 40 == 0)
		fractal_retarget(maxit);
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
	static const char *const ascii_star[] = { ".", "+", "*" }, *const uni_star[] = { "·", "✦", "★" };
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
		struct cell *c = &grid[y * cols + x];
		shade(c, 0.3 + b * 0.3, 0.55);
		c->g = unicode ? uni_star[b] : ascii_star[b];
	}
}

static int mode = 1;

static void reset_effect(void)
{
	free(iters);
	if (!(iters = calloc((size_t)rows * (size_t)cols, sizeof(int))))
		exit(1);
	for (int i = 0; i < 256; i++) {
		star_reset(&stars[i]);
		stars[i].z = (float)(rnd(950) + 50) / 1000.0f;
	}
	memset(grid, 0, (size_t)rows * (size_t)cols * sizeof(*grid));
}

int main(int argc, char **argv)
{
	int delay = 50;   /* milliseconds per frame */
	int paused = 0, opt;
	while ((opt = getopt(argc, argv, "um:")) != -1) {
		if (opt == 'u')
			unicode = 1;
		else if (opt == 'm' && optarg[0] >= '1' && optarg[0] <= '4' && !optarg[1])
			mode = optarg[0] - '0';
		else {
			fputs("usage: pixel [-u] [-m 1|2|3|4]\n"
			      "  -u  Unicode blocks and 256 colours (graphical terminals)\n"
			      "  -m  1 plasma, 2 tunnel, 3 fractal, 4 stars\n"
			      "  keys: 1-4 effect, + - speed, c colours, p pause, q quit\n", stderr);
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
			case '1': case '2': case '3': case '4': mode = k - '0'; reset_effect(); break;
			case '+': case '=': if (delay > 10) delay -= 10; break;
			case '-': case '_': if (delay < 300) delay += 10; break;
			case 'c': palette++; break;
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
			switch (mode) {
			case 1: plasma_step(); break;
			case 2: tunnel_step(); break;
			case 3: fractal_step(); break;
			default: stars_step(); break;
			}
			draw();
			t += 0.06;
		}
		struct timespec ts = { 0, delay * 1000000L };
		nanosleep(&ts, NULL);
	}
	return 0;
}

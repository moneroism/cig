/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* sys.h - commands, the install log, components (recipes) and hardware */
#ifndef SYS_H
#define SYS_H

#include <stdbool.h>
#include <stddef.h>

extern const char *LOG;   /* /var/log/cig-install.log */

void *xmalloc(size_t n);
char *xstrdup(const char *s);
char *xasprintf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* called about once a second while a command runs (to redraw progress) */
extern void (*run_tick)(void);

/* run a command, its output appended to the log; returns the exit status */
int run(char *const argv[]);
/* run a command with stdin from a string (passwords never reach the log) */
int run_input(char *const argv[], const char *input);
/* a command's stdout (NULL if it failed); stderr goes to the log */
char *capture(char *const argv[]);
/* the same with stdin from a string (secrets: never in argv, never in the log) */
char *capture_input(char *const argv[], const char *input);
bool file_exists(const char *p);
char *read_text(const char *p);

struct comp {
	char name[64], group[32], desc[160];
	bool on;
};
/* components offered by the recipes (group= other than base); base packages in *base */
int load_components(const char *share, struct comp **out, char **base);

struct drv {
	char name[64];
	char *files;   /* firmware files the driver requests, space-separated */
	bool on;
};
/* loaded drivers that request firmware (no CPU microcode); lsmod copied to lsmod_out */
int detect_hardware(struct drv **out, const char *lsmod_out);

#endif

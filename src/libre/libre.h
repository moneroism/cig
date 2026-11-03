/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* libre-meter: how much of a system is free software (FSF's definition), shared by smoke
 * (smoke libre, an installed system) and the installer (the system about to be installed).
 * Data: <share>/libre/licenses-fsf (SPDX isFsfLibre), <share>/libre/licenses-cig (reviewed
 * additions), <share>/libre/alternatives (free replacements) and a firmware index
 * (<path> TAB free|non-free TAB <driver> TAB <why>, from linux-firmware's WHENCE). */
#ifndef LIBRE_H
#define LIBRE_H

#include <stdbool.h>
#include <stddef.h>

enum libre_class { LIBRE_FREE, LIBRE_NONFREE, LIBRE_UNREVIEWED };

struct libre_item {
	char kind[12];            /* "package", "firmware", "kernel" */
	char name[200];
	enum libre_class cls;
	char why[200];            /* the license (expression) or firmware licence */
	char alt[200];            /* a free replacement that loses no function, "" if none */
};

struct libre {
	struct libre_item *v;
	int n, cap;
	/* data */
	char **free_ids;          /* licenses counted as free, sorted */
	size_t nfree_ids;
	char **fw;                /* firmware index lines, sorted by path */
	size_t nfw;
	char **alt;               /* "firmware <non-free> <free>" lines */
	size_t nalt;
};

/* reads the data below share (and the firmware index, if fwindex is not NULL); false with a
 * message on stderr if the license lists are missing */
bool libre_init(struct libre *l, const char *share, const char *fwindex);
void libre_free(struct libre *l);

/* the class of an SPDX expression (OR: free if any part is; AND: only if all are; WITH: the
 * license before it decides) */
enum libre_class libre_license(const struct libre *l, const char *expr);

/* whether the firmware index lists this file (a driver may request files linux-firmware does
 * not ship) */
bool libre_fw_has(const struct libre *l, const char *path);

/* the free replacement of a firmware file (libre/alternatives), NULL if none */
const char *libre_fw_alternative(const struct libre *l, const char *path);

/* items: a package with its license expression (linux and linux-firmware are counted as the
 * kernel and as firmware files instead: they are skipped), a firmware file */
void libre_add_package(struct libre *l, const char *name, const char *license);
void libre_add_firmware(struct libre *l, const char *path);
/* any other item, e.g. firmware whose licences were never recorded */
void libre_add_item(struct libre *l, const char *kind, const char *name, enum libre_class cls, const char *why);
/* the kernel: not free while it loads non-free firmware; call after all firmware */
void libre_add_kernel(struct libre *l, const char *name, const char *license);

/* scores in percent: overall = free items / all items; possible = the same with every free
 * replacement used; vs_possible = overall / possible */
void libre_scores(const struct libre *l, int *overall, int *possible, int *vs_possible,
                  int *nfree, int *nnonfree, int *nunreviewed);

/* the report as text (caller frees): scores, the non-free and not-reviewed items with their
 * licences, the suggestions, and what lies outside cig */
char *libre_report(const struct libre *l);

#endif

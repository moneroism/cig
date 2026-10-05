/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/*
 * disk.h - the partition layout: what the installer will keep, create and format.
 *
 * Existing partitions keep their place (and IDs); new ones go into free space
 * (first fit, "rest" takes the largest gap). Nothing is written while the layout
 * is edited: the whole table becomes one sfdisk script at the end.
 * Pure logic, no UI and no device access, so it can be tested on any machine.
 */
#ifndef DISK_H
#define DISK_H

#include <stdbool.h>
#include <stdint.h>

#define MAX_PARTS 128

enum kind { K_ESP, K_LINUX, K_SWAP, K_OTHER };

struct part {
	bool isnew;
	int num;               /* existing: its number; after layout_place: for all */
	uint64_t start, size;  /* sectors; new: size 0 = rest; start set by layout_place */
	enum kind kind;
	char fs[16];           /* existing filesystem ("" = none) */
	char mkfs[16];         /* filesystem when formatted */
	char mount[8];         /* "/", "/home", "/boot", "swap" or "" */
	bool format;
	char name[80];         /* existing GPT name */
	char *line;            /* existing: the partition's line of `sfdisk -d` */
	uint64_t pstart, psize;   /* placed position (layout_place) */
};

struct layout {
	char disk[64];         /* e.g. "sda", "nvme0n1" */
	bool wipe;             /* new partition table (the whole disk is erased) */
	uint64_t sect, align, first, last;   /* sector size, 1 MiB in sectors, usable range */
	char *header;          /* kept table: label/label-id/unit/first-lba/last-lba/sector-size */
	struct part p[MAX_PARTS];
	int n;
	struct part orig[MAX_PARTS];   /* the disk before editing (for "deleted") */
	int norig;
	uint64_t free;         /* unused space after placing (sectors) */
};

extern const char *const FS_LINUX[];   /* filesystems offered for / and /home */

void layout_clear(struct layout *l, const char *disk, uint64_t sect, uint64_t total_sectors);
/* parse `sfdisk -d` output; fs_of(dev) returns the filesystem type of a partition or "" */
void layout_load(struct layout *l, const char *disk, uint64_t sect, uint64_t total_sectors,
                 const char *dump, const char *(*fs_of)(const char *dev));
void layout_auto(struct layout *l, bool sep_home, unsigned root_g, unsigned swap_g);
int layout_new(struct layout *l, enum kind k, uint64_t sectors, const char *mount);
void layout_del(struct layout *l, int i);
/* false if this kind of partition can't have that mount point (nothing changes) */
bool layout_set_mount(struct layout *l, int i, const char *mount);

/* place new partitions; returns NULL or a message */
const char *layout_place(struct layout *l);
/* problems that stop an install, one per line; "" if none (caller frees) */
char *layout_check(struct layout *l);
/* the complete new table as sfdisk input (after a successful layout_place; caller frees) */
char *table_script(const struct layout *l);
/* GPT name for partition i ("" = leave unchanged) */
const char *part_name(const struct layout *l, int i);
const char *eff_fs(const struct part *p);
void part_dev(const char *disk, int num, char *out, size_t n);
bool parse_size(const char *s, uint64_t sect, uint64_t *sectors);

#endif

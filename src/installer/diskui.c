/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* diskui.c - the disk screen: choose a disk, auto layout or the partition editor */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

#include "state.h"
#include "ui.h"

char *size_h(unsigned long long b)
{
	if (b >= 1ULL << 40)
		return xasprintf("%.1fT", (double)b / (double)(1ULL << 40));
	if (b >= 1ULL << 30)
		return xasprintf("%.0fG", (double)b / (double)(1ULL << 30));
	return xasprintf("%.0fM", (double)b / (double)(1ULL << 20));
}

static unsigned long long sysnum(const char *path)
{
	char *t = read_text(path);
	unsigned long long v = t ? strtoull(t, NULL, 10) : 0;
	free(t);
	return v;
}

/* the disk this system runs from (never offered) */
static char *system_disk(void)
{
	struct stat st;
	DIR *d;
	struct dirent *e;
	char *found = NULL;
	if (stat("/", &st) != 0 || !(d = opendir("/sys/class/block")))
		return NULL;
	char *want = xasprintf("%u:%u", major(st.st_dev), minor(st.st_dev));
	while (!found && (e = readdir(d))) {
		char *p = xasprintf("/sys/class/block/%s/dev", e->d_name), *v = read_text(p);
		if (v && !strncmp(v, want, strlen(want)) && (v[strlen(want)] == '\n' || !v[strlen(want)])) {
			char *part = xasprintf("/sys/class/block/%s/partition", e->d_name);
			if (file_exists(part)) {   /* a partition: its parent disk */
				char *link = xasprintf("/sys/class/block/%s/..", e->d_name), real[512];
				if (realpath(link, real))
					found = xstrdup(strrchr(real, '/') + 1);
				free(link);
			} else {
				found = xstrdup(e->d_name);
			}
			free(part);
		}
		free(v);
		free(p);
	}
	closedir(d);
	free(want);
	return found;
}

static const char *fs_of(const char *dev)
{
	static char fs[16];
	char *argv[] = { "blkid", (char *)dev, NULL }, *out = capture(argv), *t;
	fs[0] = '\0';
	if (out && (t = strstr(out, " TYPE=\"")))
		snprintf(fs, sizeof(fs), "%.*s", (int)strcspn(t + 7, "\""), t + 7);
	free(out);
	return fs;
}

static unsigned long long sect_of(const char *disk)
{
	char *p = xasprintf("/sys/block/%s/queue/logical_block_size", disk);
	unsigned long long s = sysnum(p);
	free(p);
	return s ? s : 512;
}

static unsigned long long sectors_of(const char *disk)   /* in logical sectors */
{
	char *p = xasprintf("/sys/block/%s/size", disk);
	unsigned long long s = sysnum(p) * 512 / sect_of(disk);
	free(p);
	return s;
}

static void load(struct state *s)
{
	char *d = xasprintf("/dev/%s", s->disk), *argv[] = { "sfdisk", "-d", d, NULL }, *dump = capture(argv);
	layout_load(&s->lay, s->disk, sect_of(s->disk), sectors_of(s->disk), dump, fs_of);
	free(dump);
	free(d);
}

/* problems of the layout, or NULL; includes asking sfdisk without writing anything */
static char *problems(struct state *s)
{
	char *err = layout_check(&s->lay);
	if (*err)
		return err;
	free(err);
	char *script = table_script(&s->lay), *d = xasprintf("/dev/%s", s->disk);
	char *argv[] = { "sfdisk", "--no-act", "-q", d, NULL };
	int rc = run_input(argv, script);
	free(script);
	free(d);
	return rc ? xstrdup("sfdisk rejects this table (details in the log)") : NULL;
}

static const char *kind_name(enum kind k)
{
	return k == K_ESP ? "esp" : k == K_LINUX ? "linux" : k == K_SWAP ? "swap" : "other";
}

static void choose_mount(struct state *s, int i)
{
	struct part *p = &s->lay.p[i];
	const char *opts[4];
	int n = 0, sel = 0;
	switch (p->kind) {
	case K_ESP: opts[n++] = "/boot"; break;
	case K_SWAP: opts[n++] = "swap"; break;
	case K_LINUX: opts[n++] = "/"; opts[n++] = "/home"; break;
	default:
		ui_msg("Mount point", "This partition type can't be used by cig. Delete it and add a new one.");
		return;
	}
	opts[n++] = "not used";
	int c = ui_menu("Mount point", "Where the new system uses this partition:", opts, NULL, n, &sel);
	if (c < 0)
		return;
	if (!layout_set_mount(&s->lay, i, c == n - 1 ? "" : opts[c]))
		ui_msg("Mount point", "That mount point doesn't fit this partition type.");
}

static void add_part(struct state *s)
{
	static const char *const kinds[] = { "linux", "ESP (EFI system partition)", "swap" };
	static const enum kind kv[] = { K_LINUX, K_ESP, K_SWAP };
	char size[32] = "";
	int sel = 0, k = ui_menu("Add a partition", "Type:", kinds, NULL, 3, &sel);
	uint64_t sectors;
	if (k < 0 || !ui_input("Add a partition", "Size, e.g. 512M, 40G, 1T, or rest:", size, sizeof(size), false))
		return;
	if (!parse_size(size, s->lay.sect, &sectors)) {
		ui_msg("Add a partition", "That is not a size.");
		return;
	}
	int i = layout_new(&s->lay, kv[k], sectors, "");
	if (i >= 0)
		choose_mount(s, i);
}

static void part_menu(struct state *s, int i)
{
	for (;;) {
		struct part *p = &s->lay.p[i];
		const char *items[] = { "Mount point", "Format", "Filesystem", "Delete" };
		const char *vals[] = { *p->mount ? p->mount : "not used",
		                       p->isnew ? "yes (new partition)" : p->format ? "yes" : "no (keep data)",
		                       eff_fs(p)[0] ? eff_fs(p) : "-", "" };
		int sel = 0, c = ui_menu("Partition", NULL, items, vals, 4, &sel);
		if (c < 0)
			return;
		if (c == 0) {
			choose_mount(s, i);
		} else if (c == 1) {
			if (p->isnew)
				ui_msg("Format", "New partitions are always formatted.");
			else if (!*p->mount)
				ui_msg("Format", "Give it a mount point first. Unused partitions are never touched.");
			else if (!strcmp(p->mount, "/"))
				ui_msg("Format", "The system partition is always formatted.");
			else
				p->format = !p->format;
		} else if (c == 2) {
			int nfs = 0;
			while (FS_LINUX[nfs])
				nfs++;
			if (p->kind != K_LINUX || !p->format)
				ui_msg("Filesystem", "Only for linux partitions that are formatted.");
			else if (nfs == 1)
				ui_msg("Filesystem", "Only ext4 is available for now.");
			else {
				int fsel = 0, f = ui_menu("Filesystem", NULL, (const char *const *)FS_LINUX, NULL, nfs, &fsel);
				if (f >= 0)
					snprintf(p->mkfs, sizeof(p->mkfs), "%s", FS_LINUX[f]);
			}
		} else {
			layout_del(&s->lay, i);
			return;
		}
	}
}

static bool editor(struct state *s)
{
	int sel = 0;
	for (;;) {
		const char *perr = layout_place(&s->lay);
		int n = s->lay.n, total = n + 4;
		char **items = xmalloc((size_t)total * sizeof(char *));
		char *text = xasprintf("%s#   partition    size          type   fs     mount  action",
		                       s->lay.wipe ? "The whole disk will be erased (new partition table).\n\n" : "");
		for (int i = 0; i < n; i++) {
			struct part *p = &s->lay.p[i];
			char dev[96], *sz = size_h((unsigned long long)(p->psize ? p->psize : p->size) * s->lay.sect);
			char sizecol[32];
			if (p->isnew)
				snprintf(dev, sizeof(dev), "new");
			else
				part_dev(s->disk, p->num, dev, sizeof(dev));
			if (p->isnew && !p->size)
				snprintf(sizecol, sizeof(sizecol), perr ? "rest" : "rest (%s)", sz);
			else
				snprintf(sizecol, sizeof(sizecol), "%s", sz);
			items[i] = xasprintf("%-2d %-12s %-13s %-6s %-6s %-6s %s%s%s%s", i + 1,
			                     p->isnew ? dev : dev + 5, sizecol, kind_name(p->kind),
			                     eff_fs(p)[0] ? eff_fs(p) : "-", *p->mount ? p->mount : "-",
			                     p->isnew ? "create" : p->format ? "FORMAT" : "keep",
			                     *p->name ? "  \"" : "", p->name, *p->name ? "\"" : "");
			free(sz);
		}
		items[n] = "Add a partition";
		items[n + 1] = "Erase all (start from an empty disk)";
		items[n + 2] = "Reload from disk";
		items[n + 3] = "Done";
		/* what disappears: partitions of the disk that are no longer in the layout */
		for (int o = 0; o < s->lay.norig; o++) {
			bool kept = false;
			for (int i = 0; i < n; i++)
				kept |= !s->lay.p[i].isnew && s->lay.p[i].num == s->lay.orig[o].num;
			if (!kept) {
				char dev[96];
				part_dev(s->disk, s->lay.orig[o].num, dev, sizeof(dev));
				text = xasprintf("%s\n-  %s %s \"%s\": DELETE", text, dev + 5,
				                 s->lay.orig[o].fs[0] ? s->lay.orig[o].fs : "unformatted", s->lay.orig[o].name);
			}
		}
		if (perr)
			text = xasprintf("%s\n\n!! %s", text, perr);
		else {
			char *fr = size_h((unsigned long long)s->lay.free * s->lay.sect);
			text = xasprintf("%s\n\nunused space: %s", text, fr);
			free(fr);
		}
		char *title = xasprintf("Disk /dev/%s: partitions", s->disk);
		int c = ui_menu(title, text, (const char *const *)items, NULL, total, &sel);
		free(title);
		for (int i = 0; i < n; i++)
			free(items[i]);
		free(items);
		free(text);
		if (c < 0)
			return false;
		if (c < n) {
			part_menu(s, c);
		} else if (c == n) {
			add_part(s);
		} else if (c == n + 1) {
			if (ui_yesno("Erase all", "Start from an empty disk? Nothing is written before the summary.", false))
				layout_clear(&s->lay, s->disk, s->lay.sect, sectors_of(s->disk));
		} else if (c == n + 2) {
			load(s);
		} else {
			char *err = problems(s);
			if (!err)
				return true;
			ui_msg("Problems", err);
			free(err);
		}
	}
}

static bool auto_layout(struct state *s)
{
	char buf[16];
	unsigned long long size_g = sectors_of(s->disk) * sect_of(s->disk) >> 30;
	s->sep_home = ui_yesno("Auto layout", "Separate /home partition?", s->sep_home);
	if (s->sep_home) {
		snprintf(buf, sizeof(buf), "%u", s->root_g);
		char *q = xasprintf("Size of the system partition in G (rest goes to /home), 20 to %llu:", size_g - 1);
		bool ok = ui_input("Auto layout", q, buf, sizeof(buf), false);
		free(q);
		unsigned long v = strtoul(buf, NULL, 10);
		if (!ok || v < 20 || v >= size_g) {
			ui_msg("Auto layout", "The system partition needs at least 20G and must leave room for /home.");
			return false;
		}
		s->root_g = (unsigned)v;
	}
	snprintf(buf, sizeof(buf), "%u", s->swap_g);
	if (!ui_input("Auto layout", "Swap partition in G (0 = none; swap is not encrypted):", buf, sizeof(buf), false))
		return false;
	s->swap_g = (unsigned)strtoul(buf, NULL, 10);
	layout_clear(&s->lay, s->disk, sect_of(s->disk), sectors_of(s->disk));
	layout_auto(&s->lay, s->sep_home, s->root_g, s->swap_g);
	char *err = problems(s);
	if (err) {
		ui_msg("Problems", err);
		free(err);
		return false;
	}
	return true;
}

void disk_screen(struct state *s)
{
	char *sys = system_disk(), *text = xstrdup("Choose the disk to install on.");
	char **items = NULL, **names = NULL;
	int n = 0, sel = 0;
	DIR *d = opendir("/sys/block");
	struct dirent *e;
	while (d && (e = readdir(d))) {
		const char *nm = e->d_name;
		static const char *skip[] = { ".", "loop", "ram", "zram", "sr", "fd", "dm-", "md" };
		bool sk = false;
		for (size_t i = 0; i < sizeof(skip) / sizeof(*skip); i++)
			sk |= !strncmp(nm, skip[i], strlen(skip[i]));
		unsigned long long bytes = sectors_of(nm) * sect_of(nm);
		if (sk || !bytes)
			continue;
		char *mp = xasprintf("/sys/block/%s/device/model", nm), *model = read_text(mp), *sz = size_h(bytes);
		char *rp = xasprintf("/sys/block/%s/removable", nm);
		bool removable = sysnum(rp) == 1;
		if (model)
			model[strcspn(model, "\n")] = '\0';
		if (sys && !strcmp(sys, nm)) {
			text = xasprintf("%s\n%s (%s %s) runs this system and is not offered.", text, nm, sz,
			                 model ? model : "");
		} else {
			items = realloc(items, (size_t)(n + 1) * sizeof(char *));
			names = realloc(names, (size_t)(n + 1) * sizeof(char *));
			if (!items || !names)
				exit(1);
			items[n] = xasprintf("%-10s %-7s %s%s", nm, sz, model ? model : "", removable ? " (removable)" : "");
			names[n] = xstrdup(nm);
			if (!strcmp(nm, s->disk))
				sel = n;
			n++;
		}
		free(mp); free(model); free(sz); free(rp);
	}
	if (d)
		closedir(d);
	if (!n) {
		ui_msg("Disk", "No usable disk found.");
		return;
	}
	int c = ui_menu("Disk", text, (const char *const *)items, NULL, n, &sel);
	free(text);
	if (c < 0)
		return;
	if (strcmp(s->disk, names[c]))
		s->layout_ok = false;
	snprintf(s->disk, sizeof(s->disk), "%s", names[c]);

	static const char *const modes[] = { "Auto: erase the whole disk, default layout",
	                                     "Custom: edit the partition table (keep, delete, add)" };
	int msel = 0, m = ui_menu("Partitioning", "ESP, system, optional swap and /home - or your own layout.",
	                          modes, NULL, 2, &msel);
	if (m == 0) {
		s->layout_ok = auto_layout(s);
	} else if (m == 1) {
		load(s);
		s->layout_ok = editor(s);
	}
}

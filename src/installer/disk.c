/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* disk.c - partition layout model, placement, checks and the sfdisk script */
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "disk.h"

const char *const FS_LINUX[] = { "ext4", NULL };

#define TYPE_ESP   "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
#define TYPE_LINUX "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
#define TYPE_SWAP  "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"

static void *xmalloc(size_t n)
{
	void *p = malloc(n ? n : 1);
	if (!p) {
		fputs("out of memory\n", stderr);
		exit(1);
	}
	return p;
}

static char *xstrdup(const char *s)
{
	size_t n = strlen(s) + 1;
	return memcpy(xmalloc(n), s, n);
}

/* append to a growing string */
static void cat(char **s, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void cat(char **s, const char *fmt, ...)
{
	va_list ap;
	size_t old = *s ? strlen(*s) : 0;
	int n;
	va_start(ap, fmt);
	n = vsnprintf(NULL, 0, fmt, ap);
	va_end(ap);
	char *r = realloc(*s, old + (size_t)n + 1);
	if (!r) {
		fputs("out of memory\n", stderr);
		exit(1);
	}
	va_start(ap, fmt);
	vsnprintf(r + old, (size_t)n + 1, fmt, ap);
	va_end(ap);
	*s = r;
}

static void copy(char *dst, size_t n, const char *src)
{
	snprintf(dst, n, "%s", src);
}

void part_dev(const char *disk, int num, char *out, size_t n)
{
	size_t len = strlen(disk);
	bool digit = len && isdigit((unsigned char)disk[len - 1]);   /* nvme0n1 -> nvme0n1p1 */
	snprintf(out, n, "/dev/%s%s%d", disk, digit ? "p" : "", num);
}

bool parse_size(const char *s, uint64_t sect, uint64_t *sectors)
{
	char *end;
	unsigned long long v;
	uint64_t unit;
	if (!strcmp(s, "rest")) {
		*sectors = 0;
		return true;
	}
	if (!isdigit((unsigned char)*s))
		return false;
	v = strtoull(s, &end, 10);
	switch (*end) {
	case 'M': case 'm': unit = 1ULL << 20; break;
	case 'G': case 'g': unit = 1ULL << 30; break;
	case 'T': case 't': unit = 1ULL << 40; break;
	default: return false;
	}
	if (end[1] || v == 0 || v > (UINT64_MAX / unit))
		return false;
	*sectors = v * unit / sect;
	return true;
}

static void geometry(struct layout *l, uint64_t sect, uint64_t total)
{
	l->sect = sect;
	l->align = 1048576 / sect;
	l->first = l->align;
	l->last = total - 2 - 16384 / sect;   /* backup GPT: header + 16 KiB of entries */
}

void layout_clear(struct layout *l, const char *disk, uint64_t sect, uint64_t total)
{
	for (int i = 0; i < l->n; i++)
		free(l->p[i].line);
	for (int i = 0; i < l->norig; i++)
		free(l->orig[i].line);
	free(l->header);
	memset(l, 0, sizeof(*l));
	copy(l->disk, sizeof(l->disk), disk);
	geometry(l, sect, total);
	l->wipe = true;
}

static const char *default_mkfs(enum kind k)
{
	return k == K_ESP ? "vfat" : k == K_SWAP ? "swap" : FS_LINUX[0];
}

int layout_new(struct layout *l, enum kind k, uint64_t sectors, const char *mount)
{
	if (l->n == MAX_PARTS)
		return -1;
	struct part *p = &l->p[l->n];
	memset(p, 0, sizeof(*p));
	p->isnew = true;
	p->size = sectors;
	p->kind = k;
	copy(p->mkfs, sizeof(p->mkfs), default_mkfs(k));
	copy(p->mount, sizeof(p->mount), mount);
	p->format = true;
	return l->n++;
}

void layout_del(struct layout *l, int i)
{
	if (i < 0 || i >= l->n)
		return;
	free(l->p[i].line);
	memmove(&l->p[i], &l->p[i + 1], (size_t)(l->n - i - 1) * sizeof(l->p[0]));
	l->n--;
}

/* one partition per mount point; existing ones: / is always formatted, unused never */
bool layout_set_mount(struct layout *l, int i, const char *mount)
{
	enum kind k = l->p[i].kind;
	if (k == K_OTHER || (*mount && !((k == K_LINUX && (!strcmp(mount, "/") || !strcmp(mount, "/home"))) ||
	                                 (k == K_ESP && !strcmp(mount, "/boot")) ||
	                                 (k == K_SWAP && !strcmp(mount, "swap")))))
		return false;
	if (*mount)
		for (int j = 0; j < l->n; j++)
			if (!strcmp(l->p[j].mount, mount))
				l->p[j].mount[0] = '\0';
	copy(l->p[i].mount, sizeof(l->p[i].mount), mount);
	if (!l->p[i].isnew) {
		if (!strcmp(mount, "/"))
			l->p[i].format = true;
		if (!*mount)
			l->p[i].format = false;
	}
	return true;
}

static bool field(const char *line, const char *key, char *out, size_t n)
{
	char pat[32];
	const char *s;
	snprintf(pat, sizeof(pat), "%s=", key);
	for (s = strstr(line, pat); s; s = strstr(s + 1, pat))
		if (s == line || s[-1] == ' ' || s[-1] == ',')
			break;
	if (!s)
		return false;
	s += strlen(pat);
	while (*s == ' ')
		s++;
	if (*s == '"') {
		const char *e = strchr(++s, '"');
		size_t len = e ? (size_t)(e - s) : strlen(s);
		snprintf(out, n, "%.*s", (int)len, s);
	} else {
		size_t len = strcspn(s, ",");
		while (len && s[len - 1] == ' ')
			len--;
		snprintf(out, n, "%.*s", (int)len, s);
	}
	return true;
}

void layout_load(struct layout *l, const char *disk, uint64_t sect, uint64_t total,
                 const char *dump, const char *(*fs_of)(const char *dev))
{
	char *copyd, *save = NULL;
	layout_clear(l, disk, sect, total);
	if (!dump || !strstr(dump, "label: gpt"))
		return;   /* no GPT: start from an empty disk */
	l->wipe = false;
	copyd = xstrdup(dump);
	for (char *ln = strtok_r(copyd, "\n", &save); ln; ln = strtok_r(NULL, "\n", &save)) {
		static const char *keep[] = { "label:", "label-id:", "unit:", "first-lba:", "last-lba:", "sector-size:" };
		for (size_t k = 0; k < sizeof(keep) / sizeof(*keep); k++)
			if (!strncmp(ln, keep[k], strlen(keep[k]))) {
				cat(&l->header, "%s\n", ln);
				if (k == 3)
					l->first = strtoull(ln + 10, NULL, 10);
				if (k == 4)
					l->last = strtoull(ln + 9, NULL, 10);
			}
		if (strncmp(ln, "/dev/", 5) || l->n == MAX_PARTS)
			continue;
		char dev[128], v[128];
		size_t dl = strcspn(ln, " ");
		snprintf(dev, sizeof(dev), "%.*s", (int)dl, ln);
		size_t d = strlen(dev);
		while (d && isdigit((unsigned char)dev[d - 1]))
			d--;
		if (!dev[d])
			continue;
		struct part *p = &l->p[l->n];
		memset(p, 0, sizeof(*p));
		p->num = atoi(dev + d);
		if (field(ln, "start", v, sizeof(v)))
			p->start = strtoull(v, NULL, 10);
		if (field(ln, "size", v, sizeof(v)))
			p->size = strtoull(v, NULL, 10);
		if (field(ln, "type", v, sizeof(v))) {
			for (char *c = v; *c; c++)
				*c = (char)toupper((unsigned char)*c);
			p->kind = !strcmp(v, TYPE_ESP) ? K_ESP : !strcmp(v, TYPE_LINUX) ? K_LINUX :
			          !strcmp(v, TYPE_SWAP) ? K_SWAP : K_OTHER;
		} else {
			p->kind = K_OTHER;
		}
		field(ln, "name", p->name, sizeof(p->name));
		copy(p->fs, sizeof(p->fs), fs_of ? fs_of(dev) : "");
		copy(p->mkfs, sizeof(p->mkfs), p->kind == K_OTHER ? p->fs : default_mkfs(p->kind));
		p->line = xstrdup(ln);
		l->orig[l->norig] = *p;
		l->orig[l->norig].line = xstrdup(ln);
		l->norig++;
		l->n++;
	}
	free(copyd);
}

void layout_auto(struct layout *l, bool sep_home, unsigned root_g, unsigned swap_g)
{
	char disk[64];
	uint64_t total = l->last + 2 + 16384 / l->sect, sect = l->sect;
	copy(disk, sizeof(disk), l->disk);
	layout_clear(l, disk, sect, total);
	layout_new(l, K_ESP, (512ULL << 20) / sect, "/boot");
	if (sep_home) {
		layout_new(l, K_LINUX, ((uint64_t)root_g << 30) / sect, "/");
		if (swap_g)
			layout_new(l, K_SWAP, ((uint64_t)swap_g << 30) / sect, "swap");
		layout_new(l, K_LINUX, 0, "/home");
	} else {
		layout_new(l, K_LINUX, 0, "/");
		if (swap_g)
			layout_new(l, K_SWAP, ((uint64_t)swap_g << 30) / sect, "swap");
	}
}

static uint64_t align_up(const struct layout *l, uint64_t s)
{
	return (s + l->align - 1) / l->align * l->align;
}

static char place_err[96];

const char *layout_place(struct layout *l)
{
	uint64_t gs[MAX_PARTS + 1], ge[MAX_PARTS + 1], s;
	int ng = 0, order[MAX_PARTS], nk = 0, rests = 0;
	bool used[MAX_PARTS * 2 + 2] = { false };

	l->free = 0;
	/* kept partitions, sorted by start */
	for (int i = 0; i < l->n; i++)
		if (!l->p[i].isnew)
			order[nk++] = i;
	for (int a = 1; a < nk; a++)
		for (int b = a; b > 0 && l->p[order[b]].start < l->p[order[b - 1]].start; b--) {
			int t = order[b];
			order[b] = order[b - 1];
			order[b - 1] = t;
		}
	s = l->first;   /* free gaps between the kept partitions */
	for (int j = 0; j < nk; j++) {
		const struct part *k = &l->p[order[j]];
		if (k->start > s) {
			gs[ng] = s;
			ge[ng++] = k->start - 1;
		}
		if (k->start + k->size > s)
			s = k->start + k->size;
	}
	if (s <= l->last) {
		gs[ng] = s;
		ge[ng++] = l->last;
	}

	for (int i = 0; i < l->n; i++) {   /* kept ones stay, fixed sizes first fit */
		struct part *p = &l->p[i];
		if (!p->isnew) {
			p->pstart = p->start;
			p->psize = p->size;
			if (p->num > 0 && p->num < (int)(sizeof(used) / sizeof(*used)))
				used[p->num] = true;
			continue;
		}
		if (p->size == 0) {
			rests++;
			continue;
		}
		int bi = -1;
		for (int j = 0; j < ng && bi < 0; j++) {
			s = align_up(l, gs[j]);
			if (s <= ge[j] && ge[j] - s + 1 >= p->size)
				bi = j;
		}
		if (bi < 0) {
			snprintf(place_err, sizeof(place_err), "not enough free space for partition %d", i + 1);
			return place_err;
		}
		p->pstart = align_up(l, gs[bi]);
		p->psize = p->size;
		gs[bi] = p->pstart + p->size;
	}
	if (rests > 1)
		return "only one partition can take the rest of the disk";
	for (int i = 0; i < l->n; i++) {   /* "rest": the largest gap left */
		struct part *p = &l->p[i];
		if (!p->isnew || p->size)
			continue;
		int bi = -1;
		uint64_t best = 0;
		for (int j = 0; j < ng; j++) {
			s = align_up(l, gs[j]);
			uint64_t n = s <= ge[j] ? (ge[j] - s + 1) / l->align * l->align : 0;
			if (n > best) {
				best = n;
				bi = j;
			}
		}
		if (bi < 0) {
			snprintf(place_err, sizeof(place_err), "no free space left for partition %d", i + 1);
			return place_err;
		}
		p->pstart = align_up(l, gs[bi]);
		p->psize = best;
		gs[bi] = p->pstart + best;
	}
	for (int j = 0; j < ng; j++) {
		s = align_up(l, gs[j]);
		if (s <= ge[j] && ge[j] - s + 1 >= l->align)
			l->free += ge[j] - s + 1;
	}
	/* new partitions get the lowest free numbers, in the order they lie on the disk */
	int nn = 0, news[MAX_PARTS];
	for (int i = 0; i < l->n; i++)
		if (l->p[i].isnew)
			news[nn++] = i;
	for (int a = 1; a < nn; a++)
		for (int b = a; b > 0 && l->p[news[b]].pstart < l->p[news[b - 1]].pstart; b--) {
			int t = news[b];
			news[b] = news[b - 1];
			news[b - 1] = t;
		}
	for (int j = 0; j < nn; j++) {
		int num = 1;
		while (used[num])
			num++;
		used[num] = true;
		l->p[news[j]].num = num;
	}
	return NULL;
}

const char *eff_fs(const struct part *p)
{
	return p->format ? p->mkfs : p->fs;
}

const char *part_name(const struct layout *l, int i)
{
	static char old[96];
	const struct part *p = &l->p[i];
	if (!strcmp(p->mount, "/"))
		return "cig-root";
	if (!strcmp(p->mount, "/home"))
		return "cig-home";
	if (!strcmp(p->mount, "swap"))
		return "cig-swap";
	if (!strcmp(p->mount, "/boot"))
		return p->isnew ? "ESP" : "";
	/* old cig names elsewhere are renamed: a generic kernel finds root by name */
	if (!strcmp(p->name, "cig-root") || !strcmp(p->name, "cig-home") || !strcmp(p->name, "cig-swap")) {
		snprintf(old, sizeof(old), "%s-old", p->name);
		return old;
	}
	return "";
}

static bool fs_linux(const char *fs)
{
	for (int i = 0; FS_LINUX[i]; i++)
		if (!strcmp(FS_LINUX[i], fs))
			return true;
	return false;
}

char *layout_check(struct layout *l)
{
	char *err = xstrdup("");
	int nroot = 0, nboot = 0, nhome = 0, nswap = 0;
	const char *perr = layout_place(l);
	if (perr)
		cat(&err, "%s\n", perr);
	for (int i = 0; i < l->n; i++) {
		const struct part *p = &l->p[i];
		const char *m = p->mount, *fs = eff_fs(p);
		static const char *kinds[] = { "esp", "linux", "swap", "other" };
		bool ok = !*m || (!strcmp(m, "/") && p->kind == K_LINUX) || (!strcmp(m, "/home") && p->kind == K_LINUX) ||
		          (!strcmp(m, "/boot") && p->kind == K_ESP) || (!strcmp(m, "swap") && p->kind == K_SWAP);
		if (!ok)
			cat(&err, "partition %d: a %s partition can't be %s\n", i + 1, kinds[p->kind], m);
		if (!strcmp(m, "/")) {
			nroot++;
			if (!p->format)
				cat(&err, "the system partition (/) must be formatted\n");
			if (!perr && p->psize * l->sect >> 30 < 20)
				cat(&err, "the system partition (/) needs at least 20G\n");
		} else if (!strcmp(m, "/home")) {
			nhome++;
			if (!fs_linux(fs))
				cat(&err, "/home: no ext4 filesystem to keep; format it\n");
		} else if (!strcmp(m, "/boot")) {
			nboot++;
			if (strcmp(fs, "vfat"))
				cat(&err, "/boot (ESP): no FAT filesystem to keep; format it\n");
			if (!perr && p->psize * l->sect >> 20 < 100)
				cat(&err, "the ESP needs at least 100M\n");
		} else if (!strcmp(m, "swap")) {
			nswap++;
			if (strcmp(fs, "swap"))
				cat(&err, "swap: not a swap partition yet; format it\n");
		}
	}
	if (nroot != 1)
		cat(&err, "exactly one partition must be mounted at /\n");
	if (nboot != 1)
		cat(&err, "exactly one ESP must be mounted at /boot\n");
	if (nhome > 1 || nswap > 1)
		cat(&err, "at most one /home and one swap\n");
	return err;
}

char *table_script(const struct layout *l)
{
	char *out = NULL, dev[96];
	int order[MAX_PARTS];
	cat(&out, "%s", l->wipe ? "label: gpt\nunit: sectors\n" : (l->header ? l->header : ""));
	for (int i = 0; i < l->n; i++)
		order[i] = i;
	for (int a = 1; a < l->n; a++)
		for (int b = a; b > 0 && l->p[order[b]].num < l->p[order[b - 1]].num; b--) {
			int t = order[b];
			order[b] = order[b - 1];
			order[b - 1] = t;
		}
	for (int j = 0; j < l->n; j++) {
		const struct part *p = &l->p[order[j]];
		const char *name = part_name(l, order[j]);
		if (p->isnew) {
			part_dev(l->disk, p->num, dev, sizeof(dev));
			cat(&out, "%s : start=%llu, size=%llu, type=%s", dev, (unsigned long long)p->pstart,
			    (unsigned long long)p->psize,
			    p->kind == K_ESP ? TYPE_ESP : p->kind == K_SWAP ? TYPE_SWAP : TYPE_LINUX);
			if (*name)
				cat(&out, ", name=\"%s\"", name);
			cat(&out, "\n");
		} else if (!*name) {
			cat(&out, "%s\n", p->line);
		} else {
			const char *n = strstr(p->line, "name=\"");
			if (n) {   /* replace the name, keep everything after it (attrs=...) */
				const char *e = strchr(n + 6, '"');
				cat(&out, "%.*sname=\"%s\"%s\n", (int)(n - p->line), p->line, name, e ? e + 1 : "");
			} else {
				cat(&out, "%s, name=\"%s\"\n", p->line, name);
			}
		}
	}
	return out;
}

/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* audit.c - check the system against the inventory */
#include <dirent.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "smoke.h"

static int problems;

static void flag(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void flag(const char *fmt, ...)
{
	va_list ap;
	fputs("  ", stdout);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
	problems++;
}

/* a small string -> string hash table (open addressing) */
struct map {
	char **k, **v;
	size_t cap, n;
};

static uint64_t hash(const char *s)
{
	uint64_t h = 1469598103934665603ULL;
	while (*s)
		h = (h ^ (unsigned char)*s++) * 1099511628211ULL;
	return h;
}

static void map_put(struct map *m, const char *k, const char *v)
{
	if ((m->n + 1) * 2 > m->cap) {
		struct map g = { 0 };
		g.cap = m->cap ? m->cap * 2 : 1024;
		g.k = calloc(g.cap, sizeof(char *));
		g.v = calloc(g.cap, sizeof(char *));
		if (!g.k || !g.v)
			die("out of memory");
		for (size_t i = 0; i < m->cap; i++)
			if (m->k[i]) {
				size_t j = hash(m->k[i]) & (g.cap - 1);
				while (g.k[j])
					j = (j + 1) & (g.cap - 1);
				g.k[j] = m->k[i];
				g.v[j] = m->v[i];
				g.n++;
			}
		free(m->k);
		free(m->v);
		*m = g;
	}
	size_t j = hash(k) & (m->cap - 1);
	while (m->k[j] && strcmp(m->k[j], k))
		j = (j + 1) & (m->cap - 1);
	if (m->k[j]) {
		free(m->v[j]);
	} else {
		m->k[j] = xstrdup(k);
		m->n++;
	}
	m->v[j] = xstrdup(v);
}

static const char *map_get(const struct map *m, const char *k)
{
	if (!m->cap)
		return NULL;
	size_t j = hash(k) & (m->cap - 1);
	while (m->k[j]) {
		if (!strcmp(m->k[j], k))
			return m->v[j];
		j = (j + 1) & (m->cap - 1);
	}
	return NULL;
}

/* every file and link below dir (not dirs), skipping skip; paths start with "/" relative to ROOT */
static void walk(const char *dir, const char *skip, struct strv *out, bool links_only_regular)
{
	DIR *d = opendir(dir);
	struct dirent *e;
	size_t rootlen = strlen(ROOT);
	if (!d)
		return;
	while ((e = readdir(d))) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		char *p = xasprintf("%s/%s", dir, e->d_name);
		if (skip && !strcmp(p, skip)) {
			free(p);
			continue;
		}
		if (is_real_dir(p))
			walk(p, skip, out, links_only_regular);
		else if (is_link(p) ? !links_only_regular : is_file(p))
			sv_push(out, p + rootlen);
		free(p);
	}
	closedir(d);
}

/* lexically clean an absolute path: //, /./ and /../ */
static char *clean_path(const char *p)
{
	struct strv parts = { 0 }, keep = { 0 };
	char *copy = xstrdup(p), *save = NULL, *out;
	size_t len = 2;
	for (char *c = strtok_r(copy, "/", &save); c; c = strtok_r(NULL, "/", &save)) {
		if (!strcmp(c, "."))
			continue;
		if (!strcmp(c, "..")) {
			if (keep.n)
				free(keep.v[--keep.n]);
			continue;
		}
		sv_push(&keep, c);
	}
	for (size_t i = 0; i < keep.n; i++)
		len += strlen(keep.v[i]) + 1;
	out = xmalloc(len);
	out[0] = '\0';
	for (size_t i = 0; i < keep.n; i++) {
		strcat(out, "/");
		strcat(out, keep.v[i]);
	}
	if (!keep.n)
		strcpy(out, "/");
	sv_free(&keep);
	sv_free(&parts);
	free(copy);
	return out;
}

int audit(bool quick)
{
	struct map owner = { 0 }, copypat = { 0 }, folder = { 0 };
	struct strv ign = { 0 }, usr = { 0 };
	char *ignf = xasprintf("%s/etc/smoke/audit.ignore", ROOT);

	problems = 0;
	printf("smoke audit%s\n", quick ? " (quick: package checksums skipped)" : "");
	puts("-- inventory");
	if (!exists(INV)) {
		puts("  no inventory at /usr/pkg/INVENTORY");
		return 1;
	}
	if (!inv_sealed())
		flag("INVENTORY was changed outside smoke (checksum mismatch)");
	for (size_t i = 0; i < inv_count(); i++)
		map_put(&folder, inv_at(i)->name, inv_at(i)->folder);
	{
		struct strv l = { 0 };
		read_lines(ignf, &l);
		for (size_t i = 0; i < l.n; i++)
			if (l.v[i][0] != '#')
				sv_push(&ign, l.v[i]);
		sv_free(&l);
	}

	puts("-- package folders");
	{
		DIR *d = opendir(PKGROOT);
		struct dirent *e;
		while (d && (e = readdir(d))) {
			if (e->d_name[0] == '.')
				continue;
			char *pd = xasprintf("%s/%s", PKGROOT, e->d_name);
			if (!is_real_dir(pd)) {
				free(pd);
				continue;
			}
			const char *f = map_get(&folder, e->d_name);
			if (!f) {
				flag("/usr/pkg/%s is not in the inventory (installed outside smoke?)", e->d_name);
			} else {
				DIR *b = opendir(pd);
				struct dirent *be;
				while (b && (be = readdir(b))) {
					if (be->d_name[0] == '.')
						continue;
					char *bd = xasprintf("%s/%s", pd, be->d_name);
					if (is_real_dir(bd) && strcmp(be->d_name, f))
						flag("/usr/pkg/%s/%s: stale build folder", e->d_name, be->d_name);
					free(bd);
				}
				if (b)
					closedir(b);
			}
			free(pd);
		}
		if (d)
			closedir(d);
	}
	for (size_t i = 0; i < inv_count(); i++) {
		const struct inv_ent *e = inv_at(i);
		char *D = xasprintf("%s/%s/%s", PKGROOT, e->name, e->folder);
		if (!is_real_dir(D)) {
			flag("%s is in the inventory but its folder is missing", e->name);
			free(D);
			continue;
		}
		/* file -> owner index, and each package's copy_files patterns */
		struct strv files = { 0 }, sums = { 0 };
		char *ff = xasprintf("%s/.meta/FILES", D), *lp = xasprintf("%s/.meta/LAYOUT", D);
		char *layout = read_file(lp), *cp = layout ? strstr(layout, "copy_files=\"") : NULL;
		read_lines(ff, &files);
		for (size_t j = 0; j < files.n; j++)
			map_put(&owner, files.v[j], e->name);
		if (cp) {
			cp += strlen("copy_files=\"");
			cp[strcspn(cp, "\"")] = '\0';
		}
		map_put(&copypat, e->name, cp ? cp : "");
		if (!quick) {
			char *sf = xasprintf("%s/.meta/SUMS", D), hex[65];
			fprintf(stderr, "\r   checking package files: %zu/%zu %-30s", i + 1, inv_count(), e->name);
			read_lines(sf, &sums);
			for (size_t j = 0; j < sums.n; j++) {
				const char *l = sums.v[j], *rel = strstr(l, "  ");
				if (!rel)
					continue;
				rel += 2;
				char *full = xasprintf("%s/%s", D, rel);
				if (!sha256_file(full, hex) || strncmp(hex, l, 64))
					flag("%s: modified file: %s", e->name, rel);
				free(full);
			}
			free(sf);
		}
		sv_free(&files); sv_free(&sums);
		free(ff); free(lp); free(layout); free(D);
	}
	if (!quick)
		fprintf(stderr, "\r%60s\r", "");

	puts("-- /usr");
	{
		char *u = xasprintf("%s/usr", ROOT), *skip = xasprintf("%s/usr/pkg", ROOT);
		walk(u, skip, &usr, false);
		sv_sort(&usr);
		free(u); free(skip);
	}
	for (size_t i = 0; i < usr.n; i++) {
		const char *p = usr.v[i];
		char *full = xasprintf("%s%s", ROOT, p);
		if (sv_has(&ign, p)) {
			free(full);
			continue;
		}
		if (is_link(full)) {
			/* follow links that stay in /usr (outside /usr/pkg), max 8 hops */
			char *real = xstrdup(p);
			for (int hop = 0; hop < 8; hop++) {
				char *rf = xasprintf("%s%s", ROOT, real), *t;
				bool follow = starts_with(real, "/usr/") && !starts_with(real, "/usr/pkg/") &&
				              (t = read_link(rf)) != NULL;
				free(rf);
				if (!follow)
					break;
				char *d = dir_name(real), *joined = t[0] == '/' ? xstrdup(t) : xasprintf("%s/%s", d, t);
				free(real);
				real = clean_path(joined);
				free(joined); free(d); free(t);
			}
			char *rr = xasprintf("%s%s", ROOT, real);
			if (starts_with(real, "/usr/pkg/")) {
				const char *s = real + strlen("/usr/pkg/");
				char *n = xstrdup(s);
				n[strcspn(n, "/")] = '\0';
				if (!map_get(&folder, n))
					flag("%s -> %s (package not in inventory)", p, real);
				free(n);
			}
			if (!exists(rr))
				flag("%s -> %s (broken link)", p, real);
			free(rr);
			free(real);
		} else {
			const char *n = map_get(&owner, p + 1);
			if (!n)
				flag("%s: not managed by any package", p);
			else if (!matches_any(p + 1, map_get(&copypat, n)))
				flag("%s: real file where %s installs a link (replaced?)", p, n);
		}
		free(full);
	}

	puts("-- /etc (changed configuration, for information)");
	for (size_t i = 0; i < inv_count(); i++) {
		const struct inv_ent *e = inv_at(i);
		char *base = xasprintf("%s/%s/%s/.meta/root", PKGROOT, e->name, e->folder);
		char *etc = xasprintf("%s/etc", base);
		struct strv files = { 0 };
		if (is_real_dir(etc)) {
			walk(etc, NULL, &files, true);
			sv_sort(&files);
			for (size_t j = 0; j < files.n; j++) {
				/* walk() strips $ROOT; the part after .meta/root is the live path */
				char *pf = xasprintf("%s%s", ROOT, files.v[j]);
				const char *rel = strstr(pf, "/.meta/root/") + strlen("/.meta/root/");
				char *live = xasprintf("%s/%s", ROOT, rel);
				if (!exists(live))
					printf("  /%s (%s): missing\n", rel, e->name);
				else if (!same_content(pf, live))
					printf("  /%s (%s): changed\n", rel, e->name);
				free(live); free(pf);
			}
		}
		sv_free(&files);
		free(etc); free(base);
	}

	puts("-- orphans");
	for (size_t i = 0; i < inv_count(); i++) {
		struct strv users = { 0 };
		if (strcmp(inv_at(i)->reason, "dependency"))
			continue;
		needed_by(inv_at(i)->name, &users);
		if (!users.n)
			printf("  %s (nothing needs it; smoke autoremove)\n", inv_at(i)->name);
		sv_free(&users);
	}

	sv_free(&ign); sv_free(&usr);
	free(ignf);
	if (problems == 0) {
		puts("audit: clean");
		return 0;
	}
	printf("audit: %d problem(s)\n", problems);
	return 1;
}

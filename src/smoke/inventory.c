/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* inventory.c - /usr/pkg/INVENTORY: what is installed and why, sealed by a checksum */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "smoke.h"

static struct strv header;          /* the '#' lines, kept as they are */
static struct inv_ent *ents;
static size_t nents;
static bool loaded;

static void unload(void)
{
	for (size_t i = 0; i < nents; i++) {
		free(ents[i].name);
		free(ents[i].version);
		free(ents[i].reason);
		free(ents[i].depends);
		free(ents[i].sha);
		free(ents[i].folder);
	}
	free(ents);
	ents = NULL;
	nents = 0;
	sv_free(&header);
	loaded = false;
}

static void load(void)
{
	struct strv lines = { 0 };
	if (loaded)
		return;
	read_lines(INV, &lines);
	ents = xmalloc((lines.n ? lines.n : 1) * sizeof(*ents));
	for (size_t i = 0; i < lines.n; i++) {
		struct strv f = { 0 };
		if (lines.v[i][0] == '#') {
			sv_push(&header, lines.v[i]);
			continue;
		}
		sv_words(&f, lines.v[i]);
		if (f.n == 0) {
			sv_free(&f);
			continue;
		}
		if (f.n != 6)
			die("INVENTORY: malformed line: %s", lines.v[i]);
		ents[nents++] = (struct inv_ent){
			xstrdup(f.v[0]), xstrdup(f.v[1]), xstrdup(f.v[2]),
			xstrdup(f.v[3]), xstrdup(f.v[4]), xstrdup(f.v[5]),
		};
		sv_free(&f);
	}
	sv_free(&lines);
	loaded = true;
}

static void seal(void)
{
	char hex[65], *data = read_file(INV), *sumf = xasprintf("%s.sha256", INV), *line;
	if (!data)
		die("cannot read %s", INV);
	sha256_hex(data, strlen(data), hex);
	line = xasprintf("%s\n", hex);
	write_file(sumf, line);
	free(line);
	free(sumf);
	free(data);
}

bool inv_sealed(void)
{
	char hex[65], *data = read_file(INV), *sumf = xasprintf("%s.sha256", INV), *sum = read_file(sumf);
	bool ok = false;
	if (data && sum) {
		sha256_hex(data, strlen(data), hex);
		ok = strncmp(sum, hex, 64) == 0 && (sum[64] == '\n' || sum[64] == '\0');
	}
	free(data);
	free(sum);
	free(sumf);
	return ok;
}

void inv_init(void)
{
	mkdir_p(PKGROOT);
	if (!exists(INV)) {
		write_file(INV, "# smoke inventory: every installed package and why it is installed.\n"
		                "# name version reason depends package-sha256 folder\n");
		seal();
		unload();
	}
}

size_t inv_count(void)
{
	load();
	return nents;
}

const struct inv_ent *inv_at(size_t i)
{
	load();
	return i < nents ? &ents[i] : NULL;
}

const struct inv_ent *inv_get(const char *name)
{
	load();
	for (size_t i = 0; i < nents; i++)
		if (strcmp(ents[i].name, name) == 0)
			return &ents[i];
	return NULL;
}

/* rewrite: header lines first, then the package lines sorted as `sort` would (C locale) */
static void save(const char *skip, const char *extra)
{
	struct strv body = { 0 };
	char *out, *p;
	size_t len = 1;

	if (!inv_sealed())
		die("inventory checksum mismatch - refusing to write (run: smoke audit)");
	for (size_t i = 0; i < nents; i++) {
		if (skip && strcmp(ents[i].name, skip) == 0)
			continue;
		char *l = xasprintf("%s %s %s %s %s %s", ents[i].name, ents[i].version, ents[i].reason,
		                    ents[i].depends, ents[i].sha, ents[i].folder);
		sv_push(&body, l);
		free(l);
	}
	if (extra)
		sv_push(&body, extra);
	sv_sort(&body);
	for (size_t i = 0; i < header.n; i++)
		len += strlen(header.v[i]) + 1;
	for (size_t i = 0; i < body.n; i++)
		len += strlen(body.v[i]) + 1;
	p = out = xmalloc(len);
	for (size_t i = 0; i < header.n; i++)
		p += sprintf(p, "%s\n", header.v[i]);
	for (size_t i = 0; i < body.n; i++)
		p += sprintf(p, "%s\n", body.v[i]);
	write_file(INV, out);
	seal();
	free(out);
	sv_free(&body);
	unload();
}

void inv_put(const char *name, const char *version, const char *reason,
             const char *depends, const char *sha, const char *folder)
{
	char *line = xasprintf("%s %s %s %s %s %s", name, version, reason, depends, sha, folder);
	load();
	save(name, line);
	free(line);
}

void inv_del(const char *name)
{
	load();
	save(name, NULL);
}

/* packages whose depends list contains name */
void needed_by(const char *name, struct strv *out)
{
	load();
	for (size_t i = 0; i < nents; i++) {
		char *d = xstrdup(ents[i].depends), *save = NULL;
		for (char *w = strtok_r(d, ",", &save); w; w = strtok_r(NULL, ",", &save)) {
			if (strcmp(w, name) == 0) {
				sv_push(out, ents[i].name);
				break;
			}
		}
		free(d);
	}
}

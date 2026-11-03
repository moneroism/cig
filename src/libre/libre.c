/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* libre-meter: see libre.h */
#include "libre.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *xmalloc_(size_t n)
{
	void *p = malloc(n ? n : 1);
	if (!p) {
		fputs("libre: out of memory\n", stderr);
		exit(1);
	}
	return p;
}

static char *xstrdup_(const char *s)
{
	size_t n = strlen(s) + 1;
	return memcpy(xmalloc_(n), s, n);
}

static int cmp_str(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

/* lines of a file, without comments and blank lines; a comment-only file gives 0 lines */
static char **read_lines(const char *path, size_t *n, bool *ok)
{
	FILE *f = fopen(path, "r");
	char **v = NULL, buf[4096];
	size_t cap = 0;
	*n = 0;
	*ok = f != NULL;
	if (!f)
		return NULL;
	while (fgets(buf, sizeof(buf), f)) {
		buf[strcspn(buf, "\n")] = '\0';
		if (!buf[0] || buf[0] == '#')
			continue;
		if (*n == cap) {
			cap = cap ? cap * 2 : 256;
			char **r = realloc(v, cap * sizeof(*v));
			if (!r) {
				fputs("libre: out of memory\n", stderr);
				exit(1);
			}
			v = r;
		}
		v[(*n)++] = xstrdup_(buf);
	}
	fclose(f);
	return v;
}

static void free_lines(char **v, size_t n)
{
	for (size_t i = 0; i < n; i++)
		free(v[i]);
	free(v);
}

bool libre_init(struct libre *l, const char *share, const char *fwindex)
{
	char p[4096];
	size_t n1, n2;
	bool ok1, ok2, ok;
	memset(l, 0, sizeof(*l));
	snprintf(p, sizeof(p), "%s/libre/licenses-fsf", share);
	char **a = read_lines(p, &n1, &ok1);
	snprintf(p, sizeof(p), "%s/libre/licenses-cig", share);
	char **b = read_lines(p, &n2, &ok2);
	if (!ok1 || !ok2) {
		fprintf(stderr, "libre: the license lists are missing (%s/libre)\n", share);
		free_lines(a, n1);
		free_lines(b, n2);
		return false;
	}
	/* licenses-cig: "<id> <reason>": keep the id */
	l->free_ids = xmalloc_((n1 + n2) * sizeof(char *));
	for (size_t i = 0; i < n1; i++)
		l->free_ids[l->nfree_ids++] = a[i];
	for (size_t i = 0; i < n2; i++) {
		b[i][strcspn(b[i], " \t")] = '\0';
		l->free_ids[l->nfree_ids++] = b[i];
	}
	free(a);
	free(b);
	qsort(l->free_ids, l->nfree_ids, sizeof(char *), cmp_str);
	snprintf(p, sizeof(p), "%s/libre/alternatives", share);
	l->alt = read_lines(p, &l->nalt, &ok);
	if (fwindex) {
		l->fw = read_lines(fwindex, &l->nfw, &ok);
		qsort(l->fw, l->nfw, sizeof(char *), cmp_str);   /* sorted by path: the line starts with it */
	}
	return true;
}

void libre_free(struct libre *l)
{
	free_lines(l->free_ids, l->nfree_ids);
	free_lines(l->fw, l->nfw);
	free_lines(l->alt, l->nalt);
	free(l->v);
	memset(l, 0, sizeof(*l));
}

/* ---------------- SPDX expressions ---------------- */

static bool id_free(const struct libre *l, const char *id)
{
	char key[128];
	snprintf(key, sizeof(key), "%s", id);
	size_t k = strlen(key);
	if (k && key[k - 1] == '+')   /* deprecated "GPL-2.0+": the -or-later id */
		snprintf(key + k - 1, sizeof(key) - (k - 1), "-or-later");
	const char *kp = key;
	return bsearch(&kp, l->free_ids, l->nfree_ids, sizeof(char *), cmp_str) != NULL;
}

struct parser {
	const struct libre *l;
	const char *s;
	char tok[128];
};

static void next_tok(struct parser *p)
{
	while (*p->s == ' ' || *p->s == '\t')
		p->s++;
	size_t n = 0;
	if (*p->s == '(' || *p->s == ')') {
		p->tok[n++] = *p->s++;
	} else {
		while (*p->s && !strchr(" \t()", *p->s)) {
			if (n < sizeof(p->tok) - 1)
				p->tok[n++] = *p->s;
			p->s++;
		}
	}
	p->tok[n] = '\0';
}

static enum libre_class or_of(enum libre_class a, enum libre_class b)
{
	if (a == LIBRE_FREE || b == LIBRE_FREE)
		return LIBRE_FREE;
	return a == LIBRE_UNREVIEWED || b == LIBRE_UNREVIEWED ? LIBRE_UNREVIEWED : LIBRE_NONFREE;
}

static enum libre_class and_of(enum libre_class a, enum libre_class b)
{
	if (a == LIBRE_NONFREE || b == LIBRE_NONFREE)
		return LIBRE_NONFREE;
	return a == LIBRE_UNREVIEWED || b == LIBRE_UNREVIEWED ? LIBRE_UNREVIEWED : LIBRE_FREE;
}

static enum libre_class expr_or(struct parser *p);

static enum libre_class expr_atom(struct parser *p)
{
	enum libre_class c;
	if (!strcmp(p->tok, "(")) {
		next_tok(p);
		c = expr_or(p);
		if (!strcmp(p->tok, ")"))
			next_tok(p);
		return c;
	}
	if (!p->tok[0])
		return LIBRE_UNREVIEWED;
	if (!strncmp(p->tok, "LicenseRef-", 11))   /* not on any list: a person has to look */
		c = LIBRE_UNREVIEWED;
	else
		c = id_free(p->l, p->tok) ? LIBRE_FREE : LIBRE_UNREVIEWED;
	next_tok(p);
	if (!strcmp(p->tok, "WITH")) {   /* an exception only adds permissions */
		next_tok(p);
		next_tok(p);
	}
	return c;
}

static enum libre_class expr_and(struct parser *p)
{
	enum libre_class c = expr_atom(p);
	while (!strcmp(p->tok, "AND")) {
		next_tok(p);
		c = and_of(c, expr_atom(p));
	}
	return c;
}

static enum libre_class expr_or(struct parser *p)
{
	enum libre_class c = expr_and(p);
	while (!strcmp(p->tok, "OR")) {
		next_tok(p);
		c = or_of(c, expr_and(p));
	}
	return c;
}

enum libre_class libre_license(const struct libre *l, const char *expr)
{
	struct parser p = { .l = l, .s = expr ? expr : "" };
	next_tok(&p);
	return expr_or(&p);
}

/* ---------------- items ---------------- */

static struct libre_item *add_item(struct libre *l, const char *kind, const char *name,
                                   enum libre_class cls, const char *why)
{
	if (l->n == l->cap) {
		l->cap = l->cap ? l->cap * 2 : 128;
		struct libre_item *r = realloc(l->v, (size_t)l->cap * sizeof(*r));
		if (!r) {
			fputs("libre: out of memory\n", stderr);
			exit(1);
		}
		l->v = r;
	}
	struct libre_item *it = &l->v[l->n++];
	memset(it, 0, sizeof(*it));
	snprintf(it->kind, sizeof(it->kind), "%s", kind);
	snprintf(it->name, sizeof(it->name), "%s", name);
	snprintf(it->why, sizeof(it->why), "%s", why ? why : "");
	it->cls = cls;
	return it;
}

void libre_add_item(struct libre *l, const char *kind, const char *name, enum libre_class cls, const char *why)
{
	add_item(l, kind, name, cls, why);
}

void libre_add_package(struct libre *l, const char *name, const char *license)
{
	if (!strcmp(name, "linux") || !strcmp(name, "linux-firmware"))
		return;
	add_item(l, "package", name, libre_license(l, license), license && *license ? license : "no license recorded");
}

const char *libre_fw_alternative(const struct libre *l, const char *path)
{
	size_t pl = strlen(path);
	for (size_t i = 0; i < l->nalt; i++) {
		const char *a = l->alt[i];
		if (strncmp(a, "firmware ", 9))
			continue;
		a += 9;
		if (!strncmp(a, path, pl) && (a[pl] == ' ' || a[pl] == '\t')) {
			a += pl;
			return a + strspn(a, " \t");
		}
	}
	return NULL;
}

/* the index line of a file: the index is sorted by path; a line is
 * "<path>\t<class>\t<driver>\t<why>" */
static const char *fw_line(const struct libre *l, const char *path)
{
	size_t lo = 0, hi = l->nfw, pl = strlen(path);
	while (lo < hi) {
		size_t mid = (lo + hi) / 2;
		const char *m = l->fw[mid];
		int c = strncmp(m, path, pl);
		if (c == 0 && m[pl] != '\t')
			c = m[pl] < '\t' ? -1 : 1;
		if (c == 0)
			return m;
		if (c < 0)
			lo = mid + 1;
		else
			hi = mid;
	}
	return NULL;
}

bool libre_fw_has(const struct libre *l, const char *path)
{
	return fw_line(l, path) != NULL;
}

void libre_add_firmware(struct libre *l, const char *path)
{
	size_t pl = strlen(path);
	const char *line = fw_line(l, path);
	struct libre_item *it;
	if (!line) {
		it = add_item(l, "firmware", path, LIBRE_NONFREE, "not in linux-firmware's WHENCE");
	} else {
		char cls[16] = "", drv[64] = "", why[128] = "";
		const char *f = line + pl + 1, *t;
		t = strchr(f, '\t');
		snprintf(cls, sizeof(cls), "%.*s", t ? (int)(t - f) : (int)strlen(f), f);
		if (t) {
			f = t + 1;
			t = strchr(f, '\t');
			snprintf(drv, sizeof(drv), "%.*s", t ? (int)(t - f) : (int)strlen(f), f);
			if (t)
				snprintf(why, sizeof(why), "%s", t + 1);
		}
		it = add_item(l, "firmware", path, strcmp(cls, "free") ? LIBRE_NONFREE : LIBRE_FREE, why);
		/* the driver in front of the reason: the report groups by it */
		if (*drv) {
			char w[200];
			snprintf(w, sizeof(w), "%s|%s", drv, why);
			snprintf(it->why, sizeof(it->why), "%s", w);
		}
	}
	const char *alt = it->cls == LIBRE_FREE ? NULL : libre_fw_alternative(l, path);
	if (alt)
		snprintf(it->alt, sizeof(it->alt), "%s", alt);
}

void libre_add_kernel(struct libre *l, const char *name, const char *license)
{
	int blobs = 0, replaceable = 0;
	for (int i = 0; i < l->n; i++)
		if (!strcmp(l->v[i].kind, "firmware") && l->v[i].cls != LIBRE_FREE) {
			blobs++;
			replaceable += l->v[i].alt[0] != '\0';
		}
	enum libre_class c = libre_license(l, license);
	char why[200];
	if (blobs && c == LIBRE_FREE) {
		c = LIBRE_NONFREE;
		snprintf(why, sizeof(why), "%s, but it loads non-free firmware (%d of the parts here)", license, blobs);
	} else {
		snprintf(why, sizeof(why), "%s", license);
	}
	struct libre_item *it = add_item(l, "kernel", name, c, why);
	if (blobs && replaceable == blobs)
		snprintf(it->alt, sizeof(it->alt), "free once its firmware is replaced");
}

void libre_scores(const struct libre *l, int *overall, int *possible, int *vs_possible,
                  int *nfree, int *nnonfree, int *nunreviewed)
{
	int f = 0, nf = 0, u = 0, p = 0;
	for (int i = 0; i < l->n; i++) {
		switch (l->v[i].cls) {
		case LIBRE_FREE: f++; break;
		case LIBRE_NONFREE: nf++; break;
		case LIBRE_UNREVIEWED: u++; break;
		}
		p += l->v[i].cls == LIBRE_FREE || l->v[i].alt[0];
	}
	int all = l->n ? l->n : 1;
	*overall = f * 100 / all;
	*possible = p * 100 / all;
	*vs_possible = p ? f * 100 / p : 100;
	*nfree = f;
	*nnonfree = nf;
	*nunreviewed = u;
}

/* ---------------- report ---------------- */

struct buf {
	char *s;
	size_t n, cap;
};

static void bprintf(struct buf *b, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	int k = vsnprintf(NULL, 0, fmt, ap);
	va_end(ap);
	if (k < 0)
		return;
	if (b->n + (size_t)k + 1 > b->cap) {
		b->cap = (b->n + (size_t)k + 1) * 2;
		char *r = realloc(b->s, b->cap);
		if (!r) {
			fputs("libre: out of memory\n", stderr);
			exit(1);
		}
		b->s = r;
	}
	va_start(ap, fmt);
	vsnprintf(b->s + b->n, (size_t)k + 1, fmt, ap);
	va_end(ap);
	b->n += (size_t)k;
}

char *libre_report(const struct libre *l)
{
	struct buf b = { 0 };
	int ov, po, vs, nf, nn, nu;
	libre_scores(l, &ov, &po, &vs, &nf, &nn, &nu);
	bprintf(&b, "Libre overall:      %3d%%  (%d of %d parts are free software)\n", ov, nf, l->n);
	bprintf(&b, "Libre vs. possible: %3d%%  (of the %d%% this system can reach with free software)\n", vs, po);
	bprintf(&b, "Free: FSF's definition. A part is a package, a firmware file or the kernel.\n");

	if (nn) {
		bprintf(&b, "\nNot free (%d):\n", nn);
		/* firmware grouped by driver and reason; everything else one line each */
		for (int i = 0; i < l->n; i++) {
			const struct libre_item *it = &l->v[i];
			if (it->cls != LIBRE_NONFREE)
				continue;
			if (strcmp(it->kind, "firmware")) {
				bprintf(&b, "  %s %s: %s\n", it->kind, it->name, it->why);
				continue;
			}
			bool seen = false;
			for (int j = 0; j < i && !seen; j++)
				seen = l->v[j].cls == LIBRE_NONFREE && !strcmp(l->v[j].kind, "firmware") &&
				       !strcmp(l->v[j].why, it->why);
			if (seen)
				continue;
			int count = 0;
			for (int j = i; j < l->n; j++)
				count += l->v[j].cls == LIBRE_NONFREE && !strcmp(l->v[j].kind, "firmware") &&
				         !strcmp(l->v[j].why, it->why);
			const char *bar = strchr(it->why, '|');
			int dl = bar ? (int)(bar - it->why) : 0;
			const char *reason = bar ? bar + 1 : it->why;
			if (count == 1)
				bprintf(&b, "  firmware %s%s%.*s: %s\n", it->name, dl ? " for " : "", dl, it->why, reason);
			else
				bprintf(&b, "  firmware for %.*s: %d files (%s), e.g. %s\n", dl ? dl : 7,
				        dl ? it->why : "drivers", count, reason, it->name);
		}
	}
	if (nu) {
		bprintf(&b, "\nNot reviewed (%d): licenses on neither the FSF's list nor cig's reviewed list\n", nu);
		for (int i = 0; i < l->n; i++)
			if (l->v[i].cls == LIBRE_UNREVIEWED)
				bprintf(&b, "  %s %s: %s\n", l->v[i].kind, l->v[i].name, l->v[i].why);
	}

	bprintf(&b, "\nSuggestions (nothing changes unless you choose it):\n");
	int sug = 0;
	for (int i = 0; i < l->n; i++)
		if (l->v[i].cls != LIBRE_FREE && l->v[i].alt[0] && strcmp(l->v[i].kind, "kernel")) {
			bprintf(&b, "  use %s instead of %s (free, same function: rebuild linux-firmware)\n",
			        l->v[i].alt, l->v[i].name);
			sug++;
		}
	if (nn - sug > 0)
		bprintf(&b, "  Non-free firmware without a free replacement can be left out on the firmware\n"
		            "  screen; its device then may not work.\n");
	else if (!sug)
		bprintf(&b, "  none: everything counted is free software\n");

	bprintf(&b, "\nOutside cig and not counted: the UEFI firmware, Intel ME / AMD PSP, firmware\n"
	            "already stored on the devices, CPU microcode inside the UEFI firmware.\n");
	return b.s;
}

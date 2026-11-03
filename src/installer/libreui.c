/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* libreui.c - the libre-meter screen: how much of the system about to be installed is free
 * software (src/libre) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../libre/libre.h"
#include "state.h"
#include "sys.h"
#include "ui.h"

/* "\n" + a word + "\n" in a "\n"-separated list */
static bool listed(const char *list, const char *w)
{
	char *needle = xasprintf("\n%s\n", w);
	bool r = strstr(list, needle) != NULL;
	free(needle);
	return r;
}

static char *append(char *list, const char *w)
{
	char *n = xasprintf("%s%s\n", list, w);
	free(list);
	return n;
}

/* the packages to be installed: the base and the chosen components with every runtime
 * dependency, and the kernel */
static char *closure(const struct state *s)
{
	char *names = xasprintf("%s linux", s->base);
	for (int i = 0; i < s->ncomp; i++)
		if (s->comps[i].on) {
			char *n = xasprintf("%s %s", names, s->comps[i].name);
			free(names);
			names = n;
		}
	char *c = pkg_closure(s->share, names);
	free(names);
	return c;
}

/* the firmware files the install will select: the chosen drivers' files that linux-firmware
 * ships, each non-free one with a free replacement replaced by it (linux-firmware does the same) */
static char *libre_firmware_files(const struct state *s, const struct libre *l)
{
	char *list = xstrdup("\n");
	for (int i = 0; i < s->ndrv; i++) {
		if (!s->drvs[i].on)
			continue;
		char *copy = xstrdup(s->drvs[i].files), *sv = NULL;
		for (char *f = strtok_r(copy, " ", &sv); f; f = strtok_r(NULL, " ", &sv)) {
			const char *use = f, *alt;
			if (l->nfw && !libre_fw_has(l, f))
				continue;   /* not in linux-firmware: nothing is installed for it */
			if ((alt = libre_fw_alternative(l, f)) && libre_fw_has(l, alt))
				use = alt;
			if (!listed(list, use))
				list = append(list, use);
		}
		free(copy);
	}
	return list;
}

/* the meter for the current choices; false if the medium has no license data */
static bool measure(const struct state *s, struct libre *l)
{
	char *idx = xasprintf("%s/firmware.licenses", s->share);
	FILE *f = fopen(idx, "r");
	bool have_idx = f != NULL;
	if (f)
		fclose(f);
	if (!libre_init(l, s->share, have_idx ? idx : NULL)) {
		free(idx);
		return false;
	}
	free(idx);
	char *pk = closure(s);
	for (char *p = pk + 1; *p;) {
		size_t n = strcspn(p, "\n");
		char *name = xasprintf("%.*s", (int)n, p), lic[256] = "";
		p += n + (p[n] == '\n');
		char *rp = xasprintf("%s/packages/%s/recipe", s->share, name), *text = read_text(rp);
		free(rp);
		if (text) {
			recipe_value(text, "license", lic, sizeof(lic));
			free(text);
		}
		if (!strcmp(name, "linux") && !*lic)
			snprintf(lic, sizeof(lic), "GPL-2.0-only");
		if (strcmp(name, "linux"))
			libre_add_package(l, name, lic);
		free(name);
	}
	bool any_fw = false;
	for (int i = 0; i < s->ndrv; i++)
		any_fw |= s->drvs[i].on;
	if (any_fw && !have_idx) {
		libre_add_item(l, "firmware", "linux-firmware", LIBRE_NONFREE,
		               "this medium has no firmware licences (counted as non-free)");
	} else {
		char *fw = libre_firmware_files(s, l);
		for (char *p = fw + 1; *p;) {
			size_t n = strcspn(p, "\n");
			char *path = xasprintf("%.*s", (int)n, p);
			p += n + (p[n] == '\n');
			libre_add_firmware(l, path);
			free(path);
		}
		free(fw);
	}
	char *rp = xasprintf("%s/packages/linux/recipe", s->share), *text = read_text(rp), lic[256] = "GPL-2.0-only";
	free(rp);
	if (text) {
		recipe_value(text, "license", lic, sizeof(lic));
		free(text);
	}
	libre_add_kernel(l, "linux", lic);
	free(pk);
	return true;
}

char *libre_value(const struct state *s)
{
	struct libre l;
	if (!measure(s, &l))
		return xstrdup("not available (no license data)");
	int ov, po, vs, nf, nn, nu;
	libre_scores(&l, &ov, &po, &vs, &nf, &nn, &nu);
	libre_free(&l);
	return xasprintf("%d%% libre, %d%% of what is possible", ov, vs);
}

void libre_screen(struct state *s)
{
	struct libre l;
	if (!measure(s, &l)) {
		ui_msg("Libre-meter", "This medium has no license data (libre/ in cig-tools).");
		return;
	}
	char *r = libre_report(&l);
	libre_free(&l);
	/* what the firmware selection already left out: the files a driver names but did not load */
	char *trim = xstrdup("");
	for (int i = 0; i < s->ndrv; i++) {
		const struct drv *d = &s->drvs[i];
		if (!d->on || d->loaded <= 0 || d->loaded == d->nreq)
			continue;
		char *t = xasprintf("%s  %s: %d of %d files (only those it loaded)\n", trim, d->name, d->loaded, d->nreq);
		free(trim);
		trim = t;
	}
	if (*trim) {
		char *t = xasprintf("%s\nFirmware left out (not needed by this machine):\n%s", r, trim);
		free(r);
		r = t;
	}
	free(trim);
	ui_text("Libre-meter", r);
	free(r);
}

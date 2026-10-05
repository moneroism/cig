/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* remove.c - remove a package's links and files, then dependencies nothing needs */
#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "smoke.h"

/* links anywhere in /usr (outside /usr/pkg) that point into name's folder */
static void unlink_owned(const char *dir, const char *name)
{
	char *pkg = xasprintf("%s/usr/pkg", ROOT);
	DIR *d = opendir(dir);
	struct dirent *e;
	if (!d) {
		free(pkg);
		return;
	}
	while ((e = readdir(d))) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		char *p = xasprintf("%s/%s", dir, e->d_name);
		if (is_link(p)) {
			char *o = link_owner(p);
			if (o && !strcmp(o, name))
				unlink(p);
			free(o);
		} else if (is_real_dir(p) && strcmp(p, pkg)) {
			unlink_owned(p, name);
		}
		free(p);
	}
	closedir(d);
	free(pkg);
}

/* like rmdir -p, but never above $ROOT */
static void rmdir_up(const char *rel)
{
	char *p = xstrdup(rel);
	while (*p && strcmp(p, ".")) {
		char *full = xasprintf("%s/%s", ROOT, p);
		int r = rmdir(full);
		free(full);
		if (r != 0)
			break;
		char *d = dir_name(p);
		free(p);
		p = d;
	}
	free(p);
}

void remove_pkg(const char *name, bool force)
{
	const struct inv_ent *e = inv_get(name);
	struct strv users = { 0 }, files = { 0 }, dirs = { 0 };
	char *D, *ff;

	if (!e)
		die("%s is not installed", name);
	needed_by(name, &users);
	if (users.n && !force) {
		char *list = xstrdup("");
		for (size_t i = 0; i < users.n; i++) {
			char *n = xasprintf("%s%s ", list, users.v[i]);
			free(list);
			list = n;
		}
		die("%s is needed by: %s", name, list);
	}
	D = xasprintf("%s/%s/%s", PKGROOT, name, e->folder);
	info("%s: removing", name);
	ff = xasprintf("%s/.meta/FILES", D);
	if (is_file(ff)) {
		char *lp = xasprintf("%s/.meta/LAYOUT", D), *layout = read_file(lp);
		bool linkdirs = layout && strstr(layout, "link_dirs=\"") &&
		                !strstr(layout, "link_dirs=\"\"");
		read_lines(ff, &files);
		for (size_t i = 0; i < files.n; i++) {
			const char *p = files.v[i];
			char *dst = xasprintf("%s/%s", ROOT, p);
			if (starts_with(p, "usr/")) {
				char *mine = xasprintf("%s/%s", D, p + 4), *o = link_owner(dst);
				if (is_link(dst) && o && !strcmp(o, name))
					unlink(dst);
				else if (is_file(dst) && !is_link(dst) && same_content(mine, dst))
					unlink(dst);   /* copy_files */
				free(mine);
				free(o);
			} else {
				char *prist = xasprintf("%s/.meta/root/%s", D, p);
				if (is_file(prist) && same_content(prist, dst))
					unlink(dst);
				else if (exists(dst))
					warn("%s: kept /%s (changed locally)", name, p);
				free(prist);
			}
			free(dst);
		}
		if (linkdirs) {   /* directory links */
			char *usr = xasprintf("%s/usr", ROOT);
			unlink_owned(usr, name);
			free(usr);
		}
		/* directories that became empty, deepest first */
		for (size_t i = 0; i < files.n; i++) {
			char *d = dir_name(files.v[i]);
			if (!sv_has(&dirs, d))
				sv_push(&dirs, d);
			free(d);
		}
		sv_sort(&dirs);
		for (size_t i = dirs.n; i-- > 0; ) {
			const char *d = dirs.v[i];
			if (!strcmp(d, "usr") || !strcmp(d, "etc") || !strcmp(d, "var") || !strcmp(d, "."))
				continue;
			rmdir_up(d);
		}
		free(layout);
		free(lp);
	}
	rm_rf(D);
	{
		char *pd = xasprintf("%s/%s", PKGROOT, name);
		rmdir(pd);
		free(pd);
	}
	inv_del(name);
	info("%s: removed", name);
	sv_free(&users); sv_free(&files); sv_free(&dirs);
	free(D); free(ff);
}

void autoremove(void)
{
	bool changed = true;
	while (changed) {
		struct strv cand = { 0 };
		changed = false;
		for (size_t i = 0; i < inv_count(); i++)
			if (!strcmp(inv_at(i)->reason, "dependency"))
				sv_push(&cand, inv_at(i)->name);
		for (size_t i = 0; i < cand.n; i++) {
			struct strv users = { 0 };
			if (!inv_get(cand.v[i]))
				continue;
			needed_by(cand.v[i], &users);
			if (users.n == 0) {
				info("%s: no longer needed", cand.v[i]);
				remove_pkg(cand.v[i], false);
				changed = true;
			}
			sv_free(&users);
		}
		sv_free(&cand);
	}
}

/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* install.c - unpack a package into its own folder and link it into the system */
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "smoke.h"

/* the fields of .PKGINFO smoke uses (shell assignments, values optionally in "") */
struct meta {
	char *name, *version, *depends, *config, *linkdirs, *copy;
	bool has_linkdirs;
};

static void free_meta(struct meta *m)
{
	free(m->name);
	free(m->version);
	free(m->depends);
	free(m->config);
	free(m->linkdirs);
	free(m->copy);
}

/* parse key=value / key="value" lines; *rel receives rel= if asked for */
static void parse_assignments(const char *text, struct meta *m, char **rel)
{
	char *copy = xstrdup(text), *save = NULL;
	for (char *l = strtok_r(copy, "\n", &save); l; l = strtok_r(NULL, "\n", &save)) {
		char *eq = strchr(l, '='), *v;
		size_t n;
		if (!eq || l[0] == '#')
			continue;
		*eq = '\0';
		v = eq + 1;
		n = strlen(v);
		if (n >= 2 && v[0] == '"' && v[n - 1] == '"') {
			v[n - 1] = '\0';
			v++;
		}
		char **slot = !strcmp(l, "name") ? &m->name : !strcmp(l, "version") ? &m->version :
		              !strcmp(l, "depends") ? &m->depends : !strcmp(l, "config_files") ? &m->config :
		              !strcmp(l, "link_dirs") ? &m->linkdirs : !strcmp(l, "copy_files") ? &m->copy :
		              (rel && !strcmp(l, "rel")) ? rel : NULL;
		if (!slot)
			continue;
		if (slot == &m->linkdirs)
			m->has_linkdirs = true;
		free(*slot);
		*slot = xstrdup(v);
	}
	free(copy);
}

static void read_meta(const char *dir, struct meta *m)
{
	char *p = xasprintf("%s/.PKGINFO", dir), *text = read_file(p), *rel = NULL;
	if (!text)
		die("%s: not a package (no .PKGINFO)", dir);
	memset(m, 0, sizeof(*m));
	parse_assignments(text, m, &rel);
	if (!m->name || !m->version || !rel)
		die("%s: incomplete .PKGINFO", p);
	char *v = xasprintf("%s-%s", m->version, rel);
	free(m->version);
	m->version = v;
	/* older packages: take the layout fields from the recipe */
	if (!m->has_linkdirs) {
		char *argv[] = { (char *)CIGBUILD, "meta", m->name, NULL };
		char *out = capture(argv);
		if (out) {
			struct meta r = { 0 };
			parse_assignments(out, &r, NULL);
			if (r.config && *r.config) {
				free(m->config);
				m->config = xstrdup(r.config);
			}
			free(m->linkdirs);
			m->linkdirs = xstrdup(r.linkdirs ? r.linkdirs : "");
			free(m->copy);
			m->copy = xstrdup(r.copy ? r.copy : "");
			free_meta(&r);
			free(out);
		}
	}
	char **fields[] = { &m->depends, &m->config, &m->linkdirs, &m->copy };
	for (size_t i = 0; i < sizeof(fields) / sizeof(*fields); i++)
		if (!*fields[i])
			*fields[i] = xstrdup("");
	free(rel);
	free(text);
	free(p);
}

/* path of the current package file for a recipe; builds it if missing */
char *pkgfile_of(const char *name, bool build)
{
	char *argv[] = { (char *)CIGBUILD, "pkgfile", (char *)name, NULL };
	char *f = capture(argv);
	if (!f || !*f)
		die("no recipe for %s", name);
	if (build && !is_file(f)) {
		char *b[] = { (char *)CIGBUILD, "build", (char *)name, NULL };
		run(b, 2);   /* progress to stderr: stdout stays clean */
		if (!is_file(f))
			die("building %s produced no package", name);
	}
	return f;
}

/* owner of a link in /usr: the package whose folder it points into */
char *link_owner(const char *path)
{
	char *t = read_link(path), *owner = NULL;
	if (t && starts_with(t, "/usr/pkg/")) {
		const char *s = t + strlen("/usr/pkg/");
		size_t n = strcspn(s, "/");
		owner = xmalloc(n + 1);
		memcpy(owner, s, n);
		owner[n] = '\0';
	}
	free(t);
	return owner;
}

static bool owned_by(const char *path, const char *name)
{
	char *o = link_owner(path);
	bool yes = o && strcmp(o, name) == 0;
	free(o);
	return yes;
}

/* build dst.smoke-new, then rename it over dst (atomic, even for the running libc) */
static void swap_in(const char *dst, bool link, const char *what)
{
	char *nw = xasprintf("%s.smoke-new", dst);
	rm_rf(nw);
	if (link) {
		if (symlink(what, nw) != 0)
			die("cannot create link %s: %s", nw, strerror(errno));
	} else {
		copy_file(what, nw);
	}
	if (is_real_dir(dst)) {
		char *old = xasprintf("%s.smoke-old", dst);
		rm_rf(old);
		if (rename(dst, old) != 0 || rename(nw, dst) != 0)
			die("cannot replace %s: %s", dst, strerror(errno));
		rm_rf(old);
		free(old);
	} else if (rename(nw, dst) != 0) {   /* replaces a file or a link, never follows it */
		die("cannot replace %s: %s", dst, strerror(errno));
	}
	free(nw);
}

static void mkdir_parent(const char *p)
{
	char *d = dir_name(p);
	mkdir_p(d);
	free(d);
}

/* checksums of every file in the package folder, as `sha256sum` prints them */
static void collect_files(const char *base, const char *rel, struct strv *out)
{
	char *dirp = *rel ? xasprintf("%s/%s", base, rel) : xstrdup(base);
	DIR *dir = opendir(dirp);
	struct dirent *e;
	if (!dir)
		die("cannot open %s: %s", dirp, strerror(errno));
	while ((e = readdir(dir))) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		if (!*rel && !strcmp(e->d_name, ".meta"))
			continue;
		char *r = *rel ? xasprintf("%s/%s", rel, e->d_name) : xstrdup(e->d_name);
		char *full = xasprintf("%s/%s", base, r);
		if (is_real_dir(full))
			collect_files(base, r, out);
		else if (!is_link(full) && is_file(full))
			sv_push(out, r);
		free(full);
		free(r);
	}
	closedir(dir);
	free(dirp);
}

static void write_sums(const char *d)
{
	struct strv files = { 0 };
	char hex[65], *out = xstrdup(""), *p = xasprintf("%s/.meta/SUMS", d);
	collect_files(d, "", &files);
	for (size_t i = 0; i < files.n; i++) {
		char *dot = xasprintf("./%s", files.v[i]);
		files.v[i] = (free(files.v[i]), dot);
	}
	sv_sort(&files);
	for (size_t i = 0; i < files.n; i++) {
		char *f = xasprintf("%s/%s", d, files.v[i] + 2);
		if (!sha256_file(f, hex))
			die("cannot read %s", f);
		char *n = xasprintf("%s%s  %s\n", out, hex, files.v[i]);
		free(out);
		out = n;
		free(f);
	}
	write_file(p, out);
	free(out);
	free(p);
	sv_free(&files);
}

/* the link_dirs entry that p lies below (and is not equal to), or NULL */
static char *link_dir_top(const char *p, const char *globs)
{
	struct strv g = { 0 };
	char *top = NULL;
	sv_words(&g, globs);
	for (size_t i = 0; i < g.n && !top; i++) {
		size_t depth = 1, len = 0;
		for (const char *c = g.v[i]; *c; c++)
			depth += *c == '/';
		for (const char *c = p; *c; c++, len++)   /* first `depth` path components of p */
			if (*c == '/' && --depth == 0)
				break;
		if (depth != 0 && p[len] == '\0')         /* p has no more components than g */
			continue;
		char *t = xmalloc(len + 1);
		memcpy(t, p, len);
		t[len] = '\0';
		if (glob_match(g.v[i], t) && strcmp(t, p) != 0)
			top = t;
		else
			free(t);
	}
	sv_free(&g);
	return top;
}

static char *join_depends(const char *depends)
{
	struct strv d = { 0 };
	char *out;
	sv_words(&d, depends);
	if (d.n == 0) {
		sv_free(&d);
		return xstrdup("-");
	}
	out = xstrdup(d.v[0]);
	for (size_t i = 1; i < d.n; i++) {
		char *n = xasprintf("%s,%s", out, d.v[i]);
		free(out);
		out = n;
	}
	sv_free(&d);
	return out;
}

void install_pkg(const char *name, const char *reason_in)
{
	char hex[65], *reason = xstrdup(reason_in), *f, *tmp, *D, *Dpart, *mypath, *id, *prevD = NULL;
	const struct inv_ent *e;
	struct strv files = { 0 }, deps = { 0 }, done_dirs = { 0 };
	struct meta m;

	inv_init();
	/* "keep": rebuilds keep the current reason (explicit for a new install) */
	if (!strcmp(reason, "keep")) {
		e = inv_get(name);
		free(reason);
		reason = xstrdup(e ? e->reason : "explicit");
	}

	f = pkgfile_of(name, true);
	if (!sha256_file(f, hex))
		die("cannot read %s", f);
	if ((e = inv_get(name)) && !strcmp(e->sha, hex)) {
		if (!strcmp(reason, "explicit") && strcmp(e->reason, "explicit")) {
			char *v = xstrdup(e->version), *d = xstrdup(e->depends), *fo = xstrdup(e->folder);
			inv_put(name, v, "explicit", d, hex, fo);
			info("%s: now marked explicit", name);
			free(v); free(d); free(fo);
		}
		free(f); free(reason);
		return;
	}

	tmp = xasprintf("%s/build/.smoke-%s", CIG_VAR, name);
	rm_rf(tmp);
	mkdir_p(tmp);
	{
		char *argv[] = { "tar", "-C", tmp, "-xzf", f, NULL };
		if (run(argv, -1) != 0)
			die("cannot unpack %s", f);
	}
	read_meta(tmp, &m);
	if (strcmp(m.name, name))
		die("%s contains %s, not %s", f, m.name, name);

	/* dependencies first */
	sv_words(&deps, m.depends);
	for (size_t i = 0; i < deps.n; i++)
		if (!inv_get(deps.v[i]))
			install_pkg(deps.v[i], "dependency");

	/* keep the old reason on upgrade (explicit wins) */
	if ((e = inv_get(name))) {
		if (strcmp(reason, "explicit")) {
			free(reason);
			reason = xstrdup(e->reason);
		}
		prevD = xasprintf("%s/%s/%s", PKGROOT, name, e->folder);
	}
	id = xasprintf("%s-%.8s", m.version, hex);
	D = xasprintf("%s/%s/%s", PKGROOT, name, id);
	Dpart = xasprintf("%s.part", D);
	mypath = xasprintf("/usr/pkg/%s/%s", name, id);
	info("%s %s: installing into %s", name, m.version, mypath);

	{
		char *p = xasprintf("%s/.FILES", tmp);
		read_lines(p, &files);
		free(p);
	}

	/* 1. the package folder */
	rm_rf(Dpart);
	{
		char *root = xasprintf("%s/.meta/root", Dpart), *usr = xasprintf("%s/usr", tmp);
		mkdir_p(root);
		if (is_real_dir(usr)) {
			DIR *dir = opendir(usr);
			struct dirent *de;
			if (!dir)
				die("cannot open %s", usr);
			while ((de = readdir(dir))) {
				if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
					continue;
				char *s = xasprintf("%s/%s", usr, de->d_name), *d = xasprintf("%s/%s", Dpart, de->d_name);
				copy_entry(s, d);
				free(s); free(d);
			}
			closedir(dir);
		}
		const char *metaf[][2] = { { ".PKGINFO", "PKGINFO" }, { ".FILES", "FILES" }, { ".INSTALL", "INSTALL" } };
		for (size_t i = 0; i < 3; i++) {
			char *s = xasprintf("%s/%s", tmp, metaf[i][0]), *d = xasprintf("%s/.meta/%s", Dpart, metaf[i][1]);
			if (i < 2 || is_file(s))
				copy_file(s, d);
			free(s); free(d);
		}
		char *layout = xasprintf("config_files=\"%s\"\nlink_dirs=\"%s\"\ncopy_files=\"%s\"\n",
		                         m.config, m.linkdirs, m.copy);
		char *lp = xasprintf("%s/.meta/LAYOUT", Dpart);
		write_file(lp, layout);
		free(layout); free(lp);
		/* pristine copies of everything outside /usr (configs etc.) */
		for (size_t i = 0; i < files.n; i++) {
			if (starts_with(files.v[i], "usr/"))
				continue;
			char *d = xasprintf("%s/%s", root, files.v[i]), *s = xasprintf("%s/%s", tmp, files.v[i]);
			mkdir_parent(d);
			copy_entry(s, d);
			free(d); free(s);
		}
		write_sums(Dpart);
		rm_rf(D);
		if (rename(Dpart, D) != 0)
			die("cannot create %s: %s", D, strerror(errno));
		free(root); free(usr);
	}

	/* 2. conflicts: a link in /usr that belongs to a different package */
	for (size_t i = 0; i < files.n; i++) {
		if (!starts_with(files.v[i], "usr/"))
			continue;
		char *dst = xasprintf("%s/%s", ROOT, files.v[i]), *o = link_owner(dst);
		if (o && strcmp(o, name) && inv_get(o)) {
			rm_rf(D);
			die("%s: /%s already belongs to %s", name, files.v[i], o);
		}
		free(o); free(dst);
	}

	/* 3. links (whole directories for link_dirs, real copies for copy_files) */
	for (size_t i = 0; i < files.n; i++) {
		const char *p = files.v[i], *rel = p + 4;
		if (!starts_with(p, "usr/"))
			continue;
		char *dst = xasprintf("%s/%s", ROOT, p), *top = link_dir_top(p, m.linkdirs);
		if (top) {
			if (!sv_has(&done_dirs, top)) {
				char *tdst = xasprintf("%s/%s", ROOT, top), *t = xasprintf("%s/%s", mypath, top + 4);
				sv_push(&done_dirs, top);
				mkdir_parent(tdst);
				swap_in(tdst, true, t);
				free(tdst); free(t);
			}
		} else {
			mkdir_parent(dst);
			if (*m.copy && matches_any(p, m.copy)) {
				char *src = xasprintf("%s/%s", D, rel);
				swap_in(dst, false, src);
				free(src);
			} else {
				char *t = xasprintf("%s/%s", mypath, rel);
				swap_in(dst, true, t);
				free(t);
			}
		}
		free(top); free(dst);
	}

	/* 4. files outside /usr: real copies; changed config files are kept */
	for (size_t i = 0; i < files.n; i++) {
		const char *p = files.v[i];
		if (starts_with(p, "usr/"))
			continue;
		char *dst = xasprintf("%s/%s", ROOT, p), *src = xasprintf("%s/%s", tmp, p);
		bool keep = false;
		mkdir_parent(dst);
		/* a config file is only protected if the USER changed it: compare with what
		 * the previous build of this package installed (its pristine copy) */
		if (is_file(dst) && !is_link(dst) && matches_any(p, m.config) && !same_content(src, dst)) {
			char *prev = prevD ? xasprintf("%s/.meta/root/%s", prevD, p) : NULL;
			if (!(prev && is_file(prev) && same_content(prev, dst))) {
				char *nw = xasprintf("%s.new", dst);
				copy_file(src, nw);
				warn("%s: /%s was changed locally, kept it. New version: /%s.new", name, p, p);
				keep = true;
				free(nw);
			}
			free(prev);
		}
		if (!keep) {
			char *t = read_link(src);
			if (t)
				swap_in(dst, true, t);
			else
				swap_in(dst, false, src);
			free(t);
		}
		free(dst); free(src);
	}

	/* 5. previous build: drop what the new one no longer has, then its folder */
	if (prevD && is_real_dir(prevD) && strcmp(prevD, D)) {
		struct strv old = { 0 };
		char *of = xasprintf("%s/.meta/FILES", prevD);
		read_lines(of, &old);
		for (size_t i = 0; i < old.n; i++) {
			const char *p = old.v[i];
			if (sv_has(&files, p))
				continue;
			char *dst = xasprintf("%s/%s", ROOT, p);
			if (starts_with(p, "usr/")) {
				if (owned_by(dst, name))
					unlink(dst);
			} else {
				char *prist = xasprintf("%s/.meta/root/%s", prevD, p);
				if (is_file(prist) && same_content(prist, dst))
					unlink(dst);
				free(prist);
			}
			free(dst);
		}
		rm_rf(prevD);
		sv_free(&old);
		free(of);
	}

	{
		char *d = join_depends(m.depends);
		inv_put(name, m.version, reason, d, hex, id);
		free(d);
	}
	rm_rf(tmp);

	if (!*ROOT) {
		char *inst = xasprintf("%s/.meta/INSTALL", D);
		if (is_file(inst)) {
			char *argv[] = { "bash", "-c", ". \"$0\"; post_install", inst, NULL };
			if (run(argv, -1) != 0)
				warn("%s: post_install failed", name);
		}
		free(inst);
	}
	info("%s %s: installed (%s)", name, m.version, reason);

	free_meta(&m);
	sv_free(&files); sv_free(&deps); sv_free(&done_dirs);
	free(f); free(tmp); free(D); free(Dpart); free(mypath); free(id); free(prevD); free(reason);
}

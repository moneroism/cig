/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* main.c - settings, commands and the questions smoke add asks */
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "smoke.h"

const char *ROOT, *PKGROOT, *INV, *CIG_VAR, *CIG_REPO, *CIGBUILD;

static const char usage_text[] =
	"  smoke add [-c|-p] [-y] <pkg>.. add and install (-c compile here, -p prebuilt, -y no questions)\n"
	"  smoke remove  <pkg>...         remove, then remove dependencies nothing needs\n"
	"  smoke autoremove               remove orphaned dependencies\n"
	"  smoke update [-c|-p] [-y] [<pkg>...]\n"
	"                                 rebuild what its recipe changed, report new upstream releases\n"
	"  smoke update --check [<pkg>..] only report\n"
	"  smoke list [-a]                installed packages, reason, who needs them (-a: all available)\n"
	"  smoke why     <pkg>            why a package is installed\n"
	"  smoke files   <pkg>            files of a package\n"
	"  smoke mark    <reason> <pkg>   set reason: explicit | dependency | build\n"
	"  smoke hooks   <pkg>... | --all run a package's setup again (busybox first)\n"
	"  smoke audit [--quick]          check the system against the inventory\n"
	"                                 (--quick skips the package checksums)\n";

static _Noreturn void usage(void)
{
	fputs(usage_text, stdout);
	exit(1);
}

static char *joined(const struct strv *s)
{
	char *out = xstrdup("");
	for (size_t i = 0; i < s->n; i++) {
		char *n = xasprintf("%s%s%s", out, i ? " " : "", s->v[i]);
		free(out);
		out = n;
	}
	return out;
}

/* ---------------- queries ---------------- */

/* the value of a recipe's "key=" line (quotes dropped), or "" */
static char *recipe_var(const char *text, const char *key)
{
	size_t kl = strlen(key);
	for (const char *l = text; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) {
		if (strncmp(l, key, kl) || l[kl] != '=')
			continue;
		const char *v = l + kl + 1;
		size_t n = strcspn(v, "\n");
		char *out = xasprintf("%.*s", (int)n, v);
		if (*out == '"' || *out == '\'') {
			memmove(out, out + 1, strlen(out));
			out[strcspn(out, "\"'")] = '\0';
		}
		return out;
	}
	return xstrdup("");
}

/* every recipe: name, group, the description from its first line, installed or not */
static void list_available(void)
{
	char *dir = xasprintf("%s/packages", CIG_REPO);
	struct strv names = { 0 };
	DIR *d = opendir(dir);
	struct dirent *de;
	if (!d)
		die("cannot read %s: %s", dir, strerror(errno));
	while ((de = readdir(d)))
		if (de->d_name[0] != '.')
			sv_push(&names, de->d_name);
	closedir(d);
	sv_sort(&names);
	printf("  %-22s %-12s %s\n", "NAME", "GROUP", "DESCRIPTION");
	for (size_t i = 0; i < names.n; i++) {
		char *p = xasprintf("%s/%s/recipe", dir, names.v[i]), *text = read_file(p);
		if (text) {
			char *group = recipe_var(text, "group"), *desc = xstrdup("");
			if (starts_with(text, "# ")) {   /* "# name - what it is" */
				const char *dash = strstr(text, " - ");
				size_t n = strcspn(text, "\n");
				if (dash && (size_t)(dash - text) < n) {
					free(desc);
					desc = xasprintf("%.*s", (int)(n - (size_t)(dash + 3 - text)), dash + 3);
				}
			}
			printf("%c %-22s %-12s %s\n", inv_get(names.v[i]) ? '*' : ' ', names.v[i],
			       *group ? group : "-", desc);
			free(group);
			free(desc);
		}
		free(text);
		free(p);
	}
	puts("\n* installed");
	sv_free(&names);
	free(dir);
}

static void list_pkgs(void)
{
	printf("%-24s %-22s %-11s %s\n", "NAME", "VERSION", "REASON", "NEEDED-BY");
	for (size_t i = 0; i < inv_count(); i++) {
		const struct inv_ent *e = inv_at(i);
		struct strv users = { 0 };
		needed_by(e->name, &users);
		char *u = joined(&users);
		printf("%-24s %-22s %-11s %s\n", e->name, e->version, e->reason, u);
		free(u);
		sv_free(&users);
	}
}

static void why_pkg(const char *name, const char *indent)
{
	const struct inv_ent *e = inv_get(name);
	struct strv users = { 0 };
	if (!e)
		die("%s is not installed", name);
	printf("%s%s (%s)\n", indent, name, e->reason);
	needed_by(name, &users);
	char *sub = xasprintf("%s  needed by ", indent);
	for (size_t i = 0; i < users.n; i++)
		why_pkg(users.v[i], sub);
	free(sub);
	sv_free(&users);
}

static void files_pkg(const char *name)
{
	const struct inv_ent *e = inv_get(name);
	struct strv files = { 0 };
	if (!e)
		die("%s is not installed", name);
	char *p = xasprintf("%s/%s/%s/.meta/FILES", PKGROOT, name, e->folder);
	read_lines(p, &files);
	for (size_t i = 0; i < files.n; i++)
		printf("/%s\n", files.v[i]);
	sv_free(&files);
	free(p);
}

static void mark_pkg(const char *reason, const char *name)
{
	const struct inv_ent *e;
	if (strcmp(reason, "explicit") && strcmp(reason, "dependency") && strcmp(reason, "build"))
		die("reason must be explicit, dependency or build");
	if (!(e = inv_get(name)))
		die("%s is not installed", name);
	char *v = xstrdup(e->version), *d = xstrdup(e->depends), *s = xstrdup(e->sha), *f = xstrdup(e->folder);
	inv_put(name, v, reason, d, s, f);
	info("%s: marked %s", name, reason);
	free(v); free(d); free(s); free(f);
}

/* ---------------- add ---------------- */

/* non-interactive -> the default */
static bool ask_yn(const char *q, bool def)
{
	char buf[64];
	if (!isatty(0))
		return def;
	printf("%s [%s] ", q, def ? "Y/n" : "y/N");
	fflush(stdout);
	if (!fgets(buf, sizeof(buf), stdin) || buf[0] == '\n')
		return def;
	return !strcmp(buf, "y\n") || !strcmp(buf, "Y\n") || !strcmp(buf, "yes\n");
}

/* a line "key:  value" of `cigbuild info` */
static char *info_field(const char *info_out, const char *key)
{
	char *copy = xstrdup(info_out), *save = NULL, *val = NULL;
	size_t kl = strlen(key);
	for (char *l = strtok_r(copy, "\n", &save); l && !val; l = strtok_r(NULL, "\n", &save))
		if (!strncmp(l, key, kl) && l[kl] == ':')
			val = xstrdup(l + kl + 1 + strspn(l + kl + 1, " "));
	free(copy);
	return val;
}

/* the first signature URL of a recipe, or NULL */
static char *recipe_signature(const char *name)
{
	char *p = xasprintf("%s/packages/%s/recipe", CIG_REPO, name), *text = read_file(p), *sig = NULL;
	char *save = NULL;
	for (char *l = text ? strtok_r(text, "\n", &save) : NULL; l && !sig; l = strtok_r(NULL, "\n", &save)) {
		if (!starts_with(l, "signature="))
			continue;
		l += strlen("signature=");
		l += *l == '"';
		l[strcspn(l, "\" \t")] = '\0';
		if (*l && strcmp(l, "-"))
			sig = xstrdup(l);
	}
	free(text);
	free(p);
	return sig;
}

/* a package file from the install media's mirror, when there is one */
static void prebuilt_from_mirror(const char *f)
{
	const char *mirror = getenv("CIG_PKG_MIRROR");
	const char *base = strrchr(f, '/') ? strrchr(f, '/') + 1 : f;
	char *m = mirror ? xasprintf("%s/%s", mirror, base) : NULL;
	if (m && is_file(m) && !is_file(f))
		copy_file(m, f);
	free(m);
}

enum compile { ASK, YES, NO };

static void add_pkg(const char *name, enum compile compile, bool yes)
{
	char *recipe = xasprintf("%s/packages/%s/recipe", CIG_REPO, name), *f, *out, *version, *src, *sig;
	const struct inv_ent *e;
	char hex[65];

	if (!is_file(recipe))
		die("unknown package: %s (name lookup and links come later; see docs/smoke.md)", name);
	free(recipe);

	if ((e = inv_get(name)) && compile != YES) {
		f = pkgfile_of(name, false);
		if (is_file(f) && sha256_file(f, hex) && !strcmp(hex, e->sha)) {
			if (strcmp(e->reason, "explicit"))
				mark_pkg("explicit", name);
			info("%s is already added", name);
			free(f);
			return;
		}
		free(f);
	}

	/* 1. compile on this device? */
	if (compile == ASK) {
		char *q = xasprintf("Compile %s on this device?", name);
		compile = yes || ask_yn(q, true) ? YES : NO;
		free(q);
	}
	f = pkgfile_of(name, false);
	if (compile == NO)   /* a prebuilt package from the install media */
		prebuilt_from_mirror(f);
	if (compile == NO && !is_file(f))
		die("%s: no prebuilt package on this system; add it with -c to compile", name);
	/* compiling for this system needs build tools; offer them once */
	if (compile == YES && !*ROOT && !in_path("cc")) {
		puts("Build tools (compiler, make, ...) are not installed; they are needed to compile.");
		if (yes || ask_yn("Install build tools now?", false))
			install_pkg("build-tools", "explicit");
		else
			die("%s: not compiled (no build tools)", name);
	}

	/* 2. what is about to be installed */
	{
		char *argv[] = { (char *)CIGBUILD, "info", (char *)name, NULL };
		if (!(out = capture(argv)))
			die("cigbuild info %s failed", name);
	}
	version = info_field(out, "version");
	src = info_field(out, "source");
	sig = recipe_signature(name);
	printf("  %s %s\n", name, version ? version : "?");
	if (src && *src) {
		char *s = src, *colons;
		s[strcspn(s, " \t")] = '\0';
		if ((colons = strstr(s, "::")))
			s = colons + 2;
		printf("  source: %s\n", s);
	}
	if (!sig)
		printf("  warning: %s has no upstream signature recorded (source checked against its pinned SHA256 only)\n", name);
	else
		printf("  signed upstream: %s\n", sig);
	printf("  build: %s\n", compile == YES ? "compile on this device" : "prebuilt package");

	/* 3. install? */
	char *q = xasprintf("Install %s?", name);
	bool go = yes || ask_yn(q, false);
	free(q);
	if (!go) {
		puts("  skipped");
	} else {
		if (compile == YES) {
			char *s = xasprintf("%s.sha256", f);
			unlink(f);
			unlink(s);
			free(s);
		}
		install_pkg(name, "explicit");
	}
	free(out); free(version); free(src); free(sig); free(f);
}

/* ---------------- update ---------------- */

static char *recipe_version(const char *name)   /* version-rel, or NULL */
{
	char *argv[] = { (char *)CIGBUILD, "info", (char *)name, NULL }, *out = capture(argv), *v;
	v = out ? info_field(out, "version") : NULL;
	free(out);
	return v;
}

/* does name need a package that is still waiting for its update? */
static bool update_waits(const char *name, const struct strv *todo, const struct strv *done)
{
	const struct inv_ent *e = inv_get(name);
	struct strv deps = { 0 };
	bool wait = false;
	if (e && strcmp(e->depends, "-")) {
		char *d = xstrdup(e->depends);
		for (char *c = d; *c; c++)
			if (*c == ',')
				*c = ' ';
		sv_words(&deps, d);
		free(d);
	}
	for (size_t j = 0; j < deps.n && !wait; j++)
		wait = strcmp(deps.v[j], name) && sv_has(todo, deps.v[j]) && !sv_has(done, deps.v[j]);
	sv_free(&deps);
	return wait;
}

/*
 * update: packages whose recipe is newer than the installed build (another version or rel)
 * are rebuilt, dependencies first, through the same questions as add. Newer upstream
 * releases are reported: applying one means updating the recipe (pin + signature check),
 * which smoke cannot do on the device yet.
 */
static int update(int argc, char **argv, bool check, enum compile compile, bool yes)
{
	struct strv names = { 0 }, todo = { 0 }, from = { 0 }, to = { 0 };
	for (int i = 0; i < argc; i++) {
		if (!inv_get(argv[i]))
			die("%s is not installed", argv[i]);
		sv_push(&names, argv[i]);
	}
	if (!argc)
		for (size_t i = 0; i < inv_count(); i++)
			sv_push(&names, inv_at(i)->name);

	/* 1. recipes that changed since the build that is installed */
	for (size_t i = 0; i < names.n; i++) {
		char *recipe = xasprintf("%s/packages/%s/recipe", CIG_REPO, names.v[i]), *v;
		if (is_file(recipe) && (v = recipe_version(names.v[i]))) {
			if (strcmp(v, inv_get(names.v[i])->version)) {
				sv_push(&todo, names.v[i]);
				sv_push(&from, inv_get(names.v[i])->version);
				sv_push(&to, v);
			}
			free(v);
		}
		free(recipe);
	}

	/* 2. upstream: newest stable releases (cigbuild latest checks several at a time) */
	info("checking upstream releases of %zu package(s)...", names.n);
	struct strv lines = { 0 };
	{
		char **av = xmalloc((names.n + 3) * sizeof(*av));
		av[0] = (char *)CIGBUILD;
		av[1] = "latest";
		for (size_t i = 0; i < names.n; i++)
			av[i + 2] = names.v[i];
		av[names.n + 2] = NULL;
		char *out = capture(av);
		if (out) {
			char *save = NULL;
			for (char *l = strtok_r(out, "\n", &save); l; l = strtok_r(NULL, "\n", &save))
				sv_push(&lines, l);
		}
		free(out);
		free(av);
	}
	sv_sort(&lines);
	int newer = 0, unknown = 0;
	for (size_t i = 0; i < lines.n; i++) {
		char n[128], rv[128], up[128], how[16];
		if (sscanf(lines.v[i], "%127s %127s %127s %15s", n, rv, up, how) != 4)
			continue;
		if (!strcmp(how, "update")) {
			if (!newer++)
				puts("New upstream releases (the recipe has to be updated first: pin + signature check):");
			printf("  %-22s %s -> %s\n", n, rv, up);
		} else if (!strcmp(how, "unknown")) {
			unknown++;
		}
	}
	if (!newer)
		puts("No newer upstream releases found.");
	if (unknown)
		printf("(%d package(s) could not be checked: offline, or the recipe needs upstream=)\n", unknown);
	sv_free(&lines);

	if (!todo.n) {
		puts("Everything installed matches its recipe.");
		sv_free(&names); sv_free(&todo); sv_free(&from); sv_free(&to);
		return 0;
	}
	puts("Recipes newer than what is installed:");
	for (size_t i = 0; i < todo.n; i++)
		printf("  %-22s %s -> %s\n", todo.v[i], from.v[i], to.v[i]);
	if (check) {
		sv_free(&names); sv_free(&todo); sv_free(&from); sv_free(&to);
		return 0;
	}

	/* 3. how, and whether */
	if (compile == ASK)
		compile = yes || ask_yn("Compile the updates on this device?", true) ? YES : NO;
	if (compile == YES && !*ROOT && !in_path("cc"))
		die("compiling needs the build tools: smoke add build-tools");
	char *q = xasprintf("Update %zu package(s)?", todo.n);
	bool go = yes || ask_yn(q, false);
	free(q);
	if (!go) {
		puts("  nothing changed");
		sv_free(&names); sv_free(&todo); sv_free(&from); sv_free(&to);
		return 0;
	}

	/* 4. dependencies first: a package waits while something it needs is still pending */
	struct strv done = { 0 };
	while (done.n < todo.n) {
		size_t pick = todo.n, first = todo.n;
		for (size_t i = 0; i < todo.n && pick == todo.n; i++) {
			if (sv_has(&done, todo.v[i]))
				continue;
			if (first == todo.n)
				first = i;
			if (!update_waits(todo.v[i], &todo, &done))
				pick = i;
		}
		if (pick == todo.n) {   /* a dependency cycle: go ahead with the first one */
			warn("%s: dependency cycle, updating it anyway", todo.v[first]);
			pick = first;
		}
		char *f = pkgfile_of(todo.v[pick], false);
		if (compile == NO) {
			prebuilt_from_mirror(f);
			if (!is_file(f))
				die("%s: no prebuilt package for %s on this system; update with -c to compile",
				    todo.v[pick], to.v[pick]);
		}
		free(f);
		install_pkg(todo.v[pick], "keep");
		sv_push(&done, todo.v[pick]);
	}
	info("%zu package(s) updated", done.n);
	sv_free(&done); sv_free(&names); sv_free(&todo); sv_free(&from); sv_free(&to);
	return 0;
}

/* ---------------- hooks ---------------- */

static bool run_hook(const char *name)
{
	const struct inv_ent *e = inv_get(name);
	if (!e)
		die("%s is not installed", name);
	char *rel = xasprintf("/usr/pkg/%s/%s/.meta/INSTALL", name, e->folder);
	char *full = xasprintf("%s%s", ROOT, rel);
	bool ok = true;
	if (is_file(full)) {
		info("%s: setup", name);
		if (*ROOT) {
			char *argv[] = { "chroot", (char *)ROOT, "/bin/bash", "-c", ". \"$0\"; post_install", rel, NULL };
			ok = run(argv, -1) == 0;
		} else {
			char *argv[] = { "bash", "-c", ". \"$0\"; post_install", rel, NULL };
			ok = run(argv, -1) == 0;
		}
	}
	free(rel);
	free(full);
	return ok;
}

static int hooks(int argc, char **argv)
{
	struct strv names = { 0 };
	int failed = 0;
	if (argc == 1 && !strcmp(argv[0], "--all")) {
		/* busybox first: its hook creates the command links the others use */
		if (inv_get("busybox"))
			sv_push(&names, "busybox");
		for (size_t i = 0; i < inv_count(); i++)
			if (strcmp(inv_at(i)->name, "busybox"))
				sv_push(&names, inv_at(i)->name);
	} else {
		for (int i = 0; i < argc; i++)
			sv_push(&names, argv[i]);
	}
	for (size_t i = 0; i < names.n; i++)
		if (!run_hook(names.v[i])) {
			warn("%s: setup failed", names.v[i]);
			failed = 1;
		}
	sv_free(&names);
	return failed;
}

/* ---------------- main ---------------- */

static void settings(void)
{
	char exe[PATH_MAX];
	const char *v;
	umask(022);   /* system files are world-readable, whatever the caller's umask is */
	ROOT = (v = getenv("SMOKE_ROOT")) ? v : "";
	PKGROOT = xasprintf("%s/usr/pkg", ROOT);
	INV = xasprintf("%s/INVENTORY", PKGROOT);
	CIG_VAR = (v = getenv("CIG_VAR")) ? v : "/var/cig";
	if (setenv("CIG_VAR", CIG_VAR, 1) != 0)
		die("setenv: %s", strerror(errno));
	if ((v = getenv("CIG_REPO"))) {
		CIG_REPO = v;
	} else {   /* recipes live next to the smoke binary */
		if (!realpath("/proc/self/exe", exe))
			die("cannot find myself: %s", strerror(errno));
		CIG_REPO = dir_name(exe);
	}
	CIGBUILD = (v = getenv("CIGBUILD")) ? v : xasprintf("%s/cigbuild", CIG_REPO);
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "";
	int n = argc - 2;
	char **args = argv + 2;

	settings();
	bool check_only = !strcmp(cmd, "update") && n > 0 && (!strcmp(args[0], "--check") || !strcmp(args[0], "-n"));
	if (geteuid() != 0 && !*ROOT && !check_only && strcmp(cmd, "list") && strcmp(cmd, "why") && strcmp(cmd, "files") &&
	    strcmp(cmd, "audit") && strcmp(cmd, "installed") && *cmd)
		die("run as root");

	if (!strcmp(cmd, "add")) {
		enum compile compile = ASK;
		bool yes = false;
		for (; n > 0 && args[0][0] == '-'; n--, args++) {
			if (!strcmp(args[0], "-c") || !strcmp(args[0], "--compile"))
				compile = YES;
			else if (!strcmp(args[0], "-p") || !strcmp(args[0], "--prebuilt"))
				compile = NO;
			else if (!strcmp(args[0], "-y") || !strcmp(args[0], "--yes"))
				yes = true;
			else
				usage();
		}
		if (n < 1)
			usage();
		for (int i = 0; i < n; i++)
			add_pkg(args[i], compile, yes);
	} else if (!strcmp(cmd, "install")) {   /* internal: used by cigbuild (--as <reason>) */
		const char *reason = "explicit";
		if (n >= 2 && !strcmp(args[0], "--as")) {
			reason = args[1];
			n -= 2;
			args += 2;
		}
		if (n < 1)
			usage();
		for (int i = 0; i < n; i++)
			install_pkg(args[i], reason);
	} else if (!strcmp(cmd, "remove")) {
		if (n < 1)
			usage();
		for (int i = 0; i < n; i++)
			remove_pkg(args[i], false);
		autoremove();
	} else if (!strcmp(cmd, "autoremove")) {
		autoremove();
	} else if (!strcmp(cmd, "update")) {
		enum compile compile = ASK;
		bool yes = false, check = false;
		for (; n > 0 && args[0][0] == '-'; n--, args++) {
			if (!strcmp(args[0], "-c") || !strcmp(args[0], "--compile"))
				compile = YES;
			else if (!strcmp(args[0], "-p") || !strcmp(args[0], "--prebuilt"))
				compile = NO;
			else if (!strcmp(args[0], "-y") || !strcmp(args[0], "--yes"))
				yes = true;
			else if (!strcmp(args[0], "-n") || !strcmp(args[0], "--check"))
				check = true;
			else
				usage();
		}
		return update(n, args, check, compile, yes);
	} else if (!strcmp(cmd, "list")) {
		if (n == 1 && (!strcmp(args[0], "-a") || !strcmp(args[0], "--all")))
			list_available();
		else if (n == 0)
			list_pkgs();
		else
			usage();
	} else if (!strcmp(cmd, "why") && n == 1) {
		why_pkg(args[0], "");
	} else if (!strcmp(cmd, "files") && n == 1) {
		files_pkg(args[0]);
	} else if (!strcmp(cmd, "mark") && n == 2) {
		mark_pkg(args[0], args[1]);
	} else if (!strcmp(cmd, "audit") && n <= 1) {
		if (n == 1 && strcmp(args[0], "--quick"))
			usage();
		return audit(n == 1);
	} else if (!strcmp(cmd, "hooks") && n >= 1) {
		return hooks(n, args);
	} else if (!strcmp(cmd, "installed") && n == 1) {   /* for cigbuild */
		return inv_get(args[0]) ? 0 : 1;
	} else {
		usage();
	}
	return 0;
}

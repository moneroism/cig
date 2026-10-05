/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/*
 * smoke - cig's package manager.
 *
 * Every package lives in its own folder:   /usr/pkg/<name>/<version>-<rel>-<id>/
 * /usr only contains links into those folders. /etc files are real copies
 * (editable); the package folder keeps the pristine version.
 * /usr/pkg/INVENTORY lists every installed package and WHY it is there.
 *
 * Same commands, inventory and package format as the shell version it replaces.
 */
#ifndef SMOKE_H
#define SMOKE_H

#include <stdbool.h>
#include <stddef.h>

/* a growable list of strings (each one owned by the list) */
struct strv {
	char **v;
	size_t n, cap;
};
void sv_push(struct strv *s, const char *str);
void sv_free(struct strv *s);
bool sv_has(const struct strv *s, const char *str);
void sv_words(struct strv *s, const char *str);   /* split on blanks */
void sv_sort(struct strv *s);

/* settings (main.c) */
extern const char *ROOT;      /* "" = this system; a directory for testing */
extern const char *PKGROOT;   /* $ROOT/usr/pkg */
extern const char *INV;       /* $PKGROOT/INVENTORY */
extern const char *CIG_VAR, *CIG_REPO, *CIGBUILD;

/* util.c */
_Noreturn void die(const char *fmt, ...);
void info(const char *fmt, ...);
void warn(const char *fmt, ...);
void *xmalloc(size_t n);
void *xrealloc(void *p, size_t n);
char *xstrdup(const char *s);
char *xasprintf(const char *fmt, ...);
bool starts_with(const char *s, const char *prefix);

bool is_link(const char *p);       /* the path itself is a symlink */
bool is_real_dir(const char *p);   /* a directory, not a link to one */
bool is_file(const char *p);       /* regular file, links followed (test -f) */
bool exists(const char *p);        /* links followed (test -e) */
char *read_link(const char *p);    /* NULL if not a link */
char *dir_name(const char *p);
void mkdir_p(const char *p);
void rm_rf(const char *p);
void copy_file(const char *src, const char *dst);    /* cp -p */
void copy_entry(const char *src, const char *dst);   /* cp -a */
bool same_content(const char *a, const char *b);     /* cmp -s */
char *read_file(const char *p);                      /* NULL if missing */
void write_file(const char *p, const char *data);    /* via p.tmp + rename */
void read_lines(const char *p, struct strv *out);    /* missing file: nothing */
int run(char *const argv[], int stdout_fd);          /* exit status; stdout_fd -1 = inherit */
char *capture(char *const argv[]);                   /* stdout, NULL on failure */
bool in_path(const char *cmd);
bool glob_match(const char *pat, const char *s);
bool matches_any(const char *p, const char *globs);  /* p matches g or g/... */

/* sha256.c */
bool sha256_file(const char *path, char hex[65]);
void sha256_hex(const void *data, size_t len, char hex[65]);

/* inventory.c: one line per package
 *   name  version-rel  reason  depends(comma or -)  package-sha256  folder */
struct inv_ent {
	char *name, *version, *reason, *depends, *sha, *folder;
};
void inv_init(void);
bool inv_sealed(void);
size_t inv_count(void);
const struct inv_ent *inv_at(size_t i);
const struct inv_ent *inv_get(const char *name);
void inv_put(const char *name, const char *version, const char *reason,
             const char *depends, const char *sha, const char *folder);
void inv_del(const char *name);
void needed_by(const char *name, struct strv *out);

/* install.c */
void install_pkg(const char *name, const char *reason);
char *pkgfile_of(const char *name, bool build);
char *link_owner(const char *path);

/* remove.c */
void remove_pkg(const char *name, bool force);
void autoremove(void);

/* audit.c */
int audit(bool quick);

#endif

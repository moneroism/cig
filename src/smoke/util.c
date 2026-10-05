/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* util.c - messages, memory, string lists, files and processes */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "smoke.h"

/* ---------------- messages ---------------- */

_Noreturn void die(const char *fmt, ...)
{
	va_list ap;
	fflush(stdout);
	fputs("!! smoke: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

void info(const char *fmt, ...)
{
	va_list ap;
	fputs("==> ", stdout);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
	fflush(stdout);
}

void warn(const char *fmt, ...)
{
	va_list ap;
	fflush(stdout);
	fputs("   ! ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

/* ---------------- memory and strings ---------------- */

void *xmalloc(size_t n)
{
	void *p = malloc(n ? n : 1);
	if (!p)
		die("out of memory");
	return p;
}

void *xrealloc(void *p, size_t n)
{
	p = realloc(p, n ? n : 1);
	if (!p)
		die("out of memory");
	return p;
}

char *xstrdup(const char *s)
{
	size_t n = strlen(s) + 1;
	return memcpy(xmalloc(n), s, n);
}

char *xasprintf(const char *fmt, ...)
{
	va_list ap;
	int n;
	char *s;

	va_start(ap, fmt);
	n = vsnprintf(NULL, 0, fmt, ap);
	va_end(ap);
	if (n < 0)
		die("formatting failed");
	s = xmalloc((size_t)n + 1);
	va_start(ap, fmt);
	vsnprintf(s, (size_t)n + 1, fmt, ap);
	va_end(ap);
	return s;
}

bool starts_with(const char *s, const char *prefix)
{
	return strncmp(s, prefix, strlen(prefix)) == 0;
}

void sv_push(struct strv *s, const char *str)
{
	if (s->n == s->cap) {
		s->cap = s->cap ? s->cap * 2 : 16;
		s->v = xrealloc(s->v, s->cap * sizeof(*s->v));
	}
	s->v[s->n++] = xstrdup(str);
}

void sv_free(struct strv *s)
{
	for (size_t i = 0; i < s->n; i++)
		free(s->v[i]);
	free(s->v);
	s->v = NULL;
	s->n = s->cap = 0;
}

bool sv_has(const struct strv *s, const char *str)
{
	for (size_t i = 0; i < s->n; i++)
		if (strcmp(s->v[i], str) == 0)
			return true;
	return false;
}

void sv_words(struct strv *s, const char *str)
{
	char *copy = xstrdup(str), *save = NULL;
	for (char *w = strtok_r(copy, " \t\n", &save); w; w = strtok_r(NULL, " \t\n", &save))
		sv_push(s, w);
	free(copy);
}

static int cmp_str(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

void sv_sort(struct strv *s)
{
	if (s->n > 1)
		qsort(s->v, s->n, sizeof(*s->v), cmp_str);
}

/* ---------------- files ---------------- */

bool is_link(const char *p)
{
	struct stat st;
	return lstat(p, &st) == 0 && S_ISLNK(st.st_mode);
}

bool is_real_dir(const char *p)
{
	struct stat st;
	return lstat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

bool is_file(const char *p)
{
	struct stat st;
	return stat(p, &st) == 0 && S_ISREG(st.st_mode);
}

bool exists(const char *p)
{
	struct stat st;
	return stat(p, &st) == 0;
}

char *read_link(const char *p)
{
	size_t cap = 256;
	for (;;) {
		char *buf = xmalloc(cap);
		ssize_t n = readlink(p, buf, cap);
		if (n < 0) {
			free(buf);
			return NULL;
		}
		if ((size_t)n < cap) {
			buf[n] = '\0';
			return buf;
		}
		free(buf);
		cap *= 2;
	}
}

char *dir_name(const char *p)
{
	const char *slash = strrchr(p, '/');
	if (!slash)
		return xstrdup(".");
	if (slash == p)
		return xstrdup("/");
	char *d = xstrdup(p);
	d[slash - p] = '\0';
	return d;
}

void mkdir_p(const char *p)
{
	char *d = xstrdup(p);
	for (char *s = d + 1; ; s++) {
		if (*s == '/' || *s == '\0') {
			char c = *s;
			*s = '\0';
			if (mkdir(d, 0755) != 0 && errno != EEXIST)
				die("cannot create %s: %s", d, strerror(errno));
			if (c == '\0')
				break;
			*s = c;
		}
	}
	if (!exists(d))
		die("cannot create %s", d);
	free(d);
}

void rm_rf(const char *p)
{
	struct stat st;
	if (lstat(p, &st) != 0) {
		if (errno == ENOENT)
			return;
		die("%s: %s", p, strerror(errno));
	}
	if (S_ISDIR(st.st_mode)) {
		DIR *dir = opendir(p);
		struct dirent *e;
		if (!dir)
			die("cannot open %s: %s", p, strerror(errno));
		while ((e = readdir(dir))) {
			if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
				continue;
			char *c = xasprintf("%s/%s", p, e->d_name);
			rm_rf(c);
			free(c);
		}
		closedir(dir);
		if (rmdir(p) != 0)
			die("cannot remove %s: %s", p, strerror(errno));
	} else if (unlink(p) != 0) {
		die("cannot remove %s: %s", p, strerror(errno));
	}
}

static void set_owner_times(int fd, const char *p, const struct stat *st, bool link)
{
	struct timespec ts[2] = { st->st_atim, st->st_mtim };
	if (geteuid() == 0) {
		int r = fd >= 0 ? fchown(fd, st->st_uid, st->st_gid)
		                : lchown(p, st->st_uid, st->st_gid);
		if (r != 0)
			die("cannot set the owner of %s: %s", p, strerror(errno));
	}
	if (!link && fd >= 0 && fchmod(fd, st->st_mode & 07777) != 0)
		die("cannot set the mode of %s: %s", p, strerror(errno));
	if (fd >= 0 ? futimens(fd, ts) : utimensat(AT_FDCWD, p, ts, AT_SYMLINK_NOFOLLOW))
		die("cannot set the times of %s: %s", p, strerror(errno));
}

void copy_file(const char *src, const char *dst)
{
	struct stat st;
	char buf[65536];
	ssize_t n;
	int in = open(src, O_RDONLY | O_CLOEXEC);
	if (in < 0 || fstat(in, &st) != 0)
		die("cannot read %s: %s", src, strerror(errno));
	int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (out < 0)
		die("cannot write %s: %s", dst, strerror(errno));
	while ((n = read(in, buf, sizeof(buf))) > 0) {
		for (ssize_t off = 0; off < n; ) {
			ssize_t w = write(out, buf + off, (size_t)(n - off));
			if (w < 0)
				die("cannot write %s: %s", dst, strerror(errno));
			off += w;
		}
	}
	if (n < 0)
		die("cannot read %s: %s", src, strerror(errno));
	set_owner_times(out, dst, &st, false);   /* owner before mode: chown clears setuid */
	if (close(out) != 0)
		die("cannot write %s: %s", dst, strerror(errno));
	close(in);
}

void copy_entry(const char *src, const char *dst)
{
	struct stat st;
	if (lstat(src, &st) != 0)
		die("cannot read %s: %s", src, strerror(errno));
	if (S_ISLNK(st.st_mode)) {
		char *t = read_link(src);
		if (!t || symlink(t, dst) != 0)
			die("cannot create link %s: %s", dst, strerror(errno));
		free(t);
		set_owner_times(-1, dst, &st, true);
	} else if (S_ISDIR(st.st_mode)) {
		DIR *dir;
		struct dirent *e;
		if (mkdir(dst, 0700) != 0 && !(errno == EEXIST && is_real_dir(dst)))
			die("cannot create %s: %s", dst, strerror(errno));
		if (!(dir = opendir(src)))
			die("cannot open %s: %s", src, strerror(errno));
		while ((e = readdir(dir))) {
			if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
				continue;
			char *s = xasprintf("%s/%s", src, e->d_name);
			char *d = xasprintf("%s/%s", dst, e->d_name);
			copy_entry(s, d);
			free(s);
			free(d);
		}
		closedir(dir);
		int fd = open(dst, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		if (fd < 0)
			die("cannot open %s: %s", dst, strerror(errno));
		set_owner_times(fd, dst, &st, false);
		close(fd);
	} else if (S_ISREG(st.st_mode)) {
		copy_file(src, dst);
	} else {
		die("%s: special files are not supported in packages", src);
	}
}

bool same_content(const char *a, const char *b)
{
	char ba[65536], bb[65536];
	bool same = false;
	FILE *fa = fopen(a, "rb"), *fb = fopen(b, "rb");
	if (fa && fb) {
		for (;;) {
			size_t na = fread(ba, 1, sizeof(ba), fa);
			size_t nb = fread(bb, 1, sizeof(bb), fb);
			if (na != nb || memcmp(ba, bb, na) != 0)
				break;
			if (na == 0) {
				same = !ferror(fa) && !ferror(fb);
				break;
			}
		}
	}
	if (fa)
		fclose(fa);
	if (fb)
		fclose(fb);
	return same;
}

char *read_file(const char *p)
{
	FILE *f = fopen(p, "rb");
	char *buf;
	size_t len = 0, cap = 4096, n;
	if (!f)
		return NULL;
	buf = xmalloc(cap);
	while ((n = fread(buf + len, 1, cap - len - 1, f)) > 0) {
		len += n;
		if (cap - len - 1 == 0)
			buf = xrealloc(buf, cap *= 2);
	}
	if (ferror(f))
		die("cannot read %s", p);
	fclose(f);
	buf[len] = '\0';
	return buf;
}

void write_file(const char *p, const char *data)
{
	char *tmp = xasprintf("%s.tmp", p);
	FILE *f = fopen(tmp, "wb");
	if (!f || fputs(data, f) == EOF || fflush(f) != 0 || fsync(fileno(f)) != 0 || fclose(f) != 0)
		die("cannot write %s: %s", tmp, strerror(errno));
	if (rename(tmp, p) != 0)
		die("cannot replace %s: %s", p, strerror(errno));
	free(tmp);
}

void read_lines(const char *p, struct strv *out)
{
	char *data = read_file(p), *save = NULL;
	if (!data)
		return;
	for (char *l = strtok_r(data, "\n", &save); l; l = strtok_r(NULL, "\n", &save))
		sv_push(out, l);
	free(data);
}

/* ---------------- processes ---------------- */

static pid_t spawn(char *const argv[], int stdout_fd)
{
	pid_t pid;
	fflush(stdout);
	fflush(stderr);
	if ((pid = fork()) < 0)
		die("fork: %s", strerror(errno));
	if (pid == 0) {
		if (stdout_fd >= 0 && dup2(stdout_fd, 1) < 0)
			_exit(127);
		execvp(argv[0], argv);
		fprintf(stderr, "!! smoke: cannot run %s: %s\n", argv[0], strerror(errno));
		_exit(127);
	}
	return pid;
}

static int wait_for(pid_t pid)
{
	int st;
	while (waitpid(pid, &st, 0) < 0)
		if (errno != EINTR)
			die("waitpid: %s", strerror(errno));
	return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}

int run(char *const argv[], int stdout_fd)
{
	return wait_for(spawn(argv, stdout_fd));
}

char *capture(char *const argv[])
{
	int fd[2];
	char *buf;
	size_t len = 0, cap = 4096;
	ssize_t n;
	pid_t pid;

	if (pipe(fd) != 0)
		die("pipe: %s", strerror(errno));
	pid = spawn(argv, fd[1]);
	close(fd[1]);
	buf = xmalloc(cap);
	while ((n = read(fd[0], buf + len, cap - len - 1)) != 0) {
		if (n < 0) {
			if (errno == EINTR)
				continue;
			die("read: %s", strerror(errno));
		}
		len += (size_t)n;
		if (cap - len - 1 == 0)
			buf = xrealloc(buf, cap *= 2);
	}
	close(fd[0]);
	buf[len] = '\0';
	if (wait_for(pid) != 0) {
		free(buf);
		return NULL;
	}
	while (len && buf[len - 1] == '\n')   /* like $(...) */
		buf[--len] = '\0';
	return buf;
}

bool in_path(const char *cmd)
{
	const char *path = getenv("PATH");
	bool found = false;
	if (!path)
		return false;
	char *copy = xstrdup(path), *save = NULL;
	for (char *d = strtok_r(copy, ":", &save); d && !found; d = strtok_r(NULL, ":", &save)) {
		char *f = xasprintf("%s/%s", d, cmd);
		found = access(f, X_OK) == 0;
		free(f);
	}
	free(copy);
	return found;
}

/* ---------------- patterns ---------------- */

bool glob_match(const char *pat, const char *s)
{
	return fnmatch(pat, s, 0) == 0;   /* like a shell case pattern: * also matches / */
}

bool matches_any(const char *p, const char *globs)
{
	struct strv g = { 0 };
	bool hit = false;
	sv_words(&g, globs);
	for (size_t i = 0; i < g.n && !hit; i++) {
		char *sub = xasprintf("%s/*", g.v[i]);
		hit = glob_match(g.v[i], p) || glob_match(sub, p);
		free(sub);
	}
	sv_free(&g);
	return hit;
}

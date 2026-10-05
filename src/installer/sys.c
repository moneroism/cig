/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* sys.c - commands, the install log, components (recipes) and hardware */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

#include "sys.h"

const char *LOG = "/var/log/cig-install.log";
void (*run_tick)(void);

void *xmalloc(size_t n)
{
	void *p = malloc(n ? n : 1);
	if (!p) {
		fputs("out of memory\n", stderr);
		exit(1);
	}
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
	va_start(ap, fmt);
	int n = vsnprintf(NULL, 0, fmt, ap);
	va_end(ap);
	char *s = xmalloc((size_t)(n < 0 ? 0 : n) + 1);
	va_start(ap, fmt);
	vsnprintf(s, (size_t)(n < 0 ? 0 : n) + 1, fmt, ap);
	va_end(ap);
	return s;
}

void logf_(const char *fmt, ...)
{
	va_list ap;
	FILE *f = fopen(LOG, "a");
	if (!f)
		return;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fclose(f);
}

bool file_exists(const char *p)
{
	struct stat st;
	return stat(p, &st) == 0;
}

char *read_text(const char *p)
{
	FILE *f = fopen(p, "rb");
	size_t len = 0, cap = 4096, n;
	char *buf;
	if (!f)
		return NULL;
	buf = xmalloc(cap);
	while ((n = fread(buf + len, 1, cap - len - 1, f)) > 0) {
		len += n;
		if (cap - len - 1 == 0) {
			char *r = realloc(buf, cap *= 2);
			if (!r)
				exit(1);
			buf = r;
		}
	}
	fclose(f);
	buf[len] = '\0';
	return buf;
}

static void log_argv(char *const argv[])
{
	FILE *f = fopen(LOG, "a");
	if (!f)
		return;
	fputs("+", f);
	for (int i = 0; argv[i]; i++)
		fprintf(f, " %s", argv[i]);
	fputc('\n', f);
	fclose(f);
}

/* fork + exec with stdout/stderr into the log (or a pipe), stdin from a pipe */
static int spawn(char *const argv[], const char *input, int out_fd)
{
	int in[2] = { -1, -1 }, logfd, st;
	pid_t pid;
	log_argv(argv);
	if (input && pipe(in) != 0)
		return 127;
	logfd = open(LOG, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
	if ((pid = fork()) < 0)
		return 127;
	if (pid == 0) {
		if (input) {
			dup2(in[0], 0);
			close(in[1]);
		} else {
			int nul = open("/dev/null", O_RDONLY);
			if (nul >= 0)
				dup2(nul, 0);
		}
		if (logfd >= 0) {
			dup2(out_fd >= 0 ? out_fd : logfd, 1);
			dup2(logfd, 2);
		}
		execvp(argv[0], argv);
		_exit(127);
	}
	if (logfd >= 0)
		close(logfd);
	if (input) {
		close(in[0]);
		for (size_t off = 0, len = strlen(input); off < len; ) {
			ssize_t w = write(in[1], input + off, len - off);
			if (w <= 0)
				break;
			off += (size_t)w;
		}
		close(in[1]);
	}
	if (out_fd >= 0)
		close(out_fd);
	for (int waited = 0;;) {   /* poll, so the progress screen can follow the log */
		pid_t r = waitpid(pid, &st, WNOHANG);
		if (r == pid)
			break;
		if (r < 0 && errno != EINTR)
			return 127;
		usleep(50000);
		if ((waited += 50) >= 1000) {
			waited = 0;
			if (run_tick)
				run_tick();
		}
	}
	return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}

int run(char *const argv[])
{
	return spawn(argv, NULL, -1);
}

int run_input(char *const argv[], const char *input)
{
	return spawn(argv, input, -1);
}

char *capture(char *const argv[])
{
	return capture_input(argv, NULL);
}

char *capture_input(char *const argv[], const char *input)
{
	/* small outputs only (sfdisk -d, blkid): a temporary file is simplest */
	char tmpl[] = "/tmp/cig-install-XXXXXX";
	int t = mkstemp(tmpl);
	if (t < 0)
		return NULL;
	int rc = spawn(argv, input, t);
	char *out = rc == 0 ? read_text(tmpl) : NULL;
	unlink(tmpl);
	if (out) {
		size_t n = strlen(out);
		while (n && out[n - 1] == '\n')
			out[--n] = '\0';
	}
	return out;
}

/* ---------------- components ---------------- */

/* value of `key=` in a recipe, quotes removed ("" if missing) */
static void recipe_value(const char *text, const char *key, char *out, size_t n)
{
	size_t kl = strlen(key);
	out[0] = '\0';
	for (const char *l = text; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) {
		if (strncmp(l, key, kl) || l[kl] != '=')
			continue;
		const char *v = l + kl + 1;
		size_t len = strcspn(v, "\n");
		if (len && v[0] == '"') {
			v++;
			len--;
		}
		if (len && v[len - 1] == '"')
			len--;
		snprintf(out, n, "%.*s", (int)len, v);
		return;
	}
}

static int group_order(const char *g)
{
	static const char *order[] = { "desktop", "network", "sound", "tools", "build" };
	for (int i = 0; i < 5; i++)
		if (!strcmp(g, order[i]))
			return i;
	return 5;
}

static int cmp_comp(const void *a, const void *b)
{
	const struct comp *x = a, *y = b;
	int d = group_order(x->group) - group_order(y->group);
	return d ? d : strcmp(x->name, y->name);
}

int load_components(const char *share, struct comp **out, char **base)
{
	char *dir = xasprintf("%s/packages", share);
	DIR *d = opendir(dir);
	struct dirent *e;
	struct comp *c = NULL;
	int n = 0, cap = 0;
	char *b = xstrdup("");
	while (d && (e = readdir(d))) {
		if (e->d_name[0] == '.')
			continue;
		char *rp = xasprintf("%s/%s/recipe", dir, e->d_name), *text = read_text(rp), g[32], def[8];
		free(rp);
		if (!text)
			continue;
		recipe_value(text, "group", g, sizeof(g));
		recipe_value(text, "default", def, sizeof(def));
		if (!strcmp(g, "base")) {
			char *nb = xasprintf("%s%s%s", b, *b ? " " : "", e->d_name);
			free(b);
			b = nb;
		} else if (*g) {
			if (n == cap) {
				cap = cap ? cap * 2 : 32;
				struct comp *r = realloc(c, (size_t)cap * sizeof(*c));
				if (!r)
					exit(1);
				c = r;
			}
			memset(&c[n], 0, sizeof(c[n]));
			snprintf(c[n].name, sizeof(c[n].name), "%.63s", e->d_name);   /* recipe names are short */
			snprintf(c[n].group, sizeof(c[n].group), "%s", g);
			c[n].on = !strcmp(def, "on");
			/* description: the first comment line of the recipe */
			if (text[0] == '#') {
				const char *s = text + 1 + strspn(text + 1, " ");
				snprintf(c[n].desc, sizeof(c[n].desc), "%.*s", (int)strcspn(s, "\n"), s);
			}
			n++;
		}
		free(text);
	}
	if (d)
		closedir(d);
	free(dir);
	if (n > 1)
		qsort(c, (size_t)n, sizeof(*c), cmp_comp);
	*out = c;
	*base = b;
	return n;
}

/* ---------------- hardware ---------------- */

/* firmware= entries in a module's .modinfo (NUL-separated strings in the file) */
static char *module_firmware(const char *ko)
{
	char *out = xstrdup("");
	FILE *f = fopen(ko, "rb");
	if (!f)
		return out;
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	rewind(f);
	if (size <= 0 || size > (64L << 20)) {
		fclose(f);
		return out;
	}
	char *buf = xmalloc((size_t)size + 1);
	size_t got = fread(buf, 1, (size_t)size, f);
	fclose(f);
	buf[got] = '\0';
	for (size_t i = 0; i + 9 < got; i++) {
		if ((i == 0 || buf[i - 1] == '\0') && !memcmp(buf + i, "firmware=", 9)) {
			const char *fw = buf + i + 9;
			if (strncmp(fw, "intel-ucode/", 12) && strncmp(fw, "amd-ucode/", 10) && *fw &&
			    !strstr(out, fw)) {   /* never CPU microcode */
				char *n = xasprintf("%s%s%s", out, *out ? " " : "", fw);
				free(out);
				out = n;
			}
		}
	}
	free(buf);
	return out;
}

/* find <name>.ko below dir, with - and _ treated alike */
static char *find_module(const char *dir, const char *name)
{
	DIR *d = opendir(dir);
	struct dirent *e;
	char *found = NULL;
	while (d && !found && (e = readdir(d))) {
		if (e->d_name[0] == '.')
			continue;
		char *p = xasprintf("%s/%s", dir, e->d_name);
		struct stat st;
		if (lstat(p, &st) == 0 && S_ISDIR(st.st_mode)) {
			found = find_module(p, name);
		} else {
			size_t l = strlen(e->d_name);
			if (l > 3 && !strcmp(e->d_name + l - 3, ".ko") && l - 3 == strlen(name)) {
				bool same = true;
				for (size_t i = 0; i < l - 3 && same; i++) {
					char a = e->d_name[i] == '-' ? '_' : e->d_name[i];
					char b = name[i] == '-' ? '_' : name[i];
					same = a == b;
				}
				if (same)
					found = xstrdup(p);
			}
		}
		free(p);
	}
	if (d)
		closedir(d);
	return found;
}

int detect_hardware(struct drv **out, const char *lsmod_out)
{
	struct utsname u;
	char *mods = read_text("/proc/modules"), *save = NULL, *kdir;
	struct drv *dv = NULL;
	int n = 0, cap = 0;
	FILE *ls = lsmod_out ? fopen(lsmod_out, "w") : NULL;
	*out = NULL;
	if (ls)   /* the same format as lsmod: the kernel build reads it */
		fputs("Module                  Size  Used by\n", ls);
	if (!mods || uname(&u) != 0) {
		if (ls)
			fclose(ls);
		free(mods);
		return 0;
	}
	kdir = xasprintf("/usr/lib/modules/%s", u.release);
	for (char *l = strtok_r(mods, "\n", &save); l; l = strtok_r(NULL, "\n", &save)) {
		char name[64], size[32], used[16];
		if (sscanf(l, "%63s %31s %15s", name, size, used) != 3)
			continue;
		if (ls)
			fprintf(ls, "%-19s %8s  %s\n", name, size, used);
		char *ko = find_module(kdir, name);
		if (!ko)
			continue;
		char *fw = module_firmware(ko);
		free(ko);
		if (!*fw) {   /* most drivers request no firmware */
			free(fw);
			continue;
		}
		if (n == cap) {
			cap = cap ? cap * 2 : 16;
			struct drv *r = realloc(dv, (size_t)cap * sizeof(*dv));
			if (!r)
				exit(1);
			dv = r;
		}
		snprintf(dv[n].name, sizeof(dv[n].name), "%s", name);
		dv[n].files = fw;
		dv[n].on = true;
		n++;
	}
	if (ls)
		fclose(ls);
	free(kdir);
	free(mods);
	*out = dv;
	return n;
}

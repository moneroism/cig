/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/*
 * fuzz.c - a small coverage-guided fuzzer for cig's own C code, with nothing to install:
 * GCC's -fsanitize-coverage=trace-pc feeds the coverage map, a guard-page malloc stands in
 * for AddressSanitizer (heap overflows past the block, use after free, double free), and
 * UBSan in trap mode needs no runtime library. Crashes, hangs and UBSan traps are saved.
 *
 *   fuzz-<target> <corpus-dir> <out-dir> [seconds]    fuzz (corpus grows; findings in out-dir)
 *   fuzz-<target> -r <file>...                        run inputs once, without fork (repro)
 *   FUZZ_VERBOSE=1: keep the workers' output; FUZZ_BATCH: inputs per worker (500)
 *
 * Safety: each worker runs under a seccomp filter that kills it on exec, fork, kill,
 * unlink, rename, rmdir, mount and similar calls: fuzzed input can never make the code
 * under test run programs or remove files. Run it as a normal user, never as root.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <setjmp.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "fuzz.h"

#define PG 4096UL
#define MAPSZ 65536
#define MAXQ 8192
#define HARD_MAX (1 << 20)

__attribute__((weak)) const char *fuzz_dict[] = { NULL };
__attribute__((weak)) size_t fuzz_max_len = 65536;
__attribute__((weak)) void fuzz_init(void);

/* ---------------- guard-page malloc ----------------
 * every block ends at a PROT_NONE page; the bytes between the requested size and the
 * 16-byte boundary hold a canary checked on free; freed blocks become PROT_NONE */

struct hdr {
	size_t magic, size, maplen;
	char *map;
};
#define LIVE 0x6c6976656c697665UL
#define CANARY 0xa5
#define QUAR 16384
static char *quar_map[QUAR];
static size_t quar_len[QUAR], quar_i;

static void say(const char *s)
{
	ssize_t r = write(2, s, strlen(s));
	(void)r;
}

static void *g_alloc(size_t n, size_t align)
{
	if (align < 16)
		align = 16;
	if (n > (1UL << 40))
		return NULL;
	size_t usz = (n + 15) & ~15UL;
	size_t data = (usz + sizeof(struct hdr) + align + PG - 1) & ~(PG - 1);
	size_t maplen = data + PG;
	char *map = mmap(NULL, maplen, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (map == MAP_FAILED) {   /* too many mappings: give quarantined blocks back */
		for (size_t i = 0; i < QUAR; i++)
			if (quar_map[i]) {
				munmap(quar_map[i], quar_len[i]);
				quar_map[i] = NULL;
			}
		map = mmap(NULL, maplen, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (map == MAP_FAILED)
			return NULL;
	}
	mprotect(map + data, PG, PROT_NONE);
	char *p = (char *)(((uintptr_t)(map + data - usz)) & ~(uintptr_t)(align - 1));
	struct hdr *h = (struct hdr *)(p - sizeof(struct hdr));
	*h = (struct hdr){ LIVE, n, maplen, map };
	memset(p + n, CANARY, (size_t)(map + data - (p + n)));
	return p;
}

void *malloc(size_t n)
{
	return g_alloc(n, 16);
}

void free(void *ptr)
{
	if (!ptr)
		return;
	struct hdr *h = (struct hdr *)((char *)ptr - sizeof(struct hdr));
	if (h->magic != LIVE) {
		say("fuzz: free() of a block that is not live (bad pointer or double free)\n");
		abort();
	}
	size_t data = h->maplen - PG;
	for (char *c = (char *)ptr + h->size; c < h->map + data; c++)
		if ((unsigned char)*c != CANARY) {
			say("fuzz: heap overflow (canary after the block changed)\n");
			abort();
		}
	char *map = h->map;
	size_t maplen = h->maplen;
	h->magic = 0;
	mprotect(map, maplen, PROT_NONE);   /* use after free -> SIGSEGV */
	if (quar_map[quar_i])
		munmap(quar_map[quar_i], quar_len[quar_i]);
	quar_map[quar_i] = map;
	quar_len[quar_i] = maplen;
	quar_i = (quar_i + 1) % QUAR;
}

void *calloc(size_t a, size_t b)
{
	if (b && a > (size_t)-1 / b)
		return NULL;
	return g_alloc(a * b, 16);   /* fresh mappings are zeroed */
}

void *realloc(void *ptr, size_t n)
{
	if (!ptr)
		return g_alloc(n, 16);
	struct hdr *h = (struct hdr *)((char *)ptr - sizeof(struct hdr));
	if (h->magic != LIVE) {
		say("fuzz: realloc() of a block that is not live\n");
		abort();
	}
	void *q = g_alloc(n, 16);
	if (!q)
		return NULL;
	memcpy(q, ptr, h->size < n ? h->size : n);
	free(ptr);
	return q;
}

int posix_memalign(void **out, size_t align, size_t n)
{
	void *p = g_alloc(n, align);
	if (!p)
		return ENOMEM;
	*out = p;
	return 0;
}

void *aligned_alloc(size_t align, size_t n)
{
	return g_alloc(n, align);
}

void *memalign(size_t align, size_t n)
{
	return g_alloc(n, align);
}

void *valloc(size_t n)
{
	return g_alloc(n, PG);
}

void *pvalloc(size_t n)
{
	return g_alloc((n + PG - 1) & ~(PG - 1), PG);
}

size_t malloc_usable_size(void *ptr)
{
	return ptr ? ((struct hdr *)((char *)ptr - sizeof(struct hdr)))->size : 0;
}

/* ---------------- coverage ---------------- */

static uint8_t trace[MAPSZ];
static uint8_t *virgin;   /* shared by all workers: bits seen so far */
static uintptr_t prev_loc;

void __sanitizer_cov_trace_pc(void);
void __sanitizer_cov_trace_pc(void)
{
	uintptr_t pc = (uintptr_t)__builtin_return_address(0);
	pc = (pc >> 4) ^ (pc << 8);
	trace[(pc ^ prev_loc) & (MAPSZ - 1)]++;
	prev_loc = pc >> 1;
}

static uint8_t bucket(uint8_t c)
{
	return c == 0 ? 0 : c == 1 ? 1 : c == 2 ? 2 : c == 3 ? 4 : c < 8 ? 8 : c < 16 ? 16 : c < 32 ? 32 : c < 128 ? 64 : 128;
}

static bool new_coverage(void)
{
	bool found = false;
	for (size_t i = 0; i < MAPSZ; i++)
		if (trace[i]) {
			uint8_t b = bucket(trace[i]);
			if (b & ~virgin[i]) {
				__atomic_fetch_or(&virgin[i], b, __ATOMIC_RELAXED);
				found = true;
			}
		}
	return found;
}

/* ---------------- exit() inside the code under test ---------------- */

static jmp_buf exit_jb;
static int in_target;
void __real_exit(int);
void __wrap_exit(int);
void __wrap_exit(int code)
{
	if (in_target)
		longjmp(exit_jb, 1);   /* die(), bad_answer(): a rejected input, not a crash */
	__real_exit(code);
}

/* ---------------- the input as a file ---------------- */

const char *fuzz_file(const uint8_t *data, size_t len)
{
	static int fd = -1;
	static char path[64];
	if (fd < 0) {
		fd = memfd_create("fuzz", 0);
		if (fd < 0) {
			perror("memfd_create");
			abort();
		}
		snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
	}
	if (ftruncate(fd, 0) != 0 || pwrite(fd, data, len, 0) != (ssize_t)len)
		abort();
	return path;
}

/* ---------------- the worker's sandbox ---------------- */

static void sandbox(void)
{
	static const int deny[] = {
		SYS_execve, SYS_execveat, SYS_fork, SYS_vfork, SYS_clone, SYS_clone3,
		SYS_kill, SYS_tkill, SYS_unlink, SYS_unlinkat, SYS_rename, SYS_renameat,
		SYS_renameat2, SYS_rmdir, SYS_truncate, SYS_mount, SYS_umount2, SYS_reboot,
		SYS_chmod, SYS_fchmodat, SYS_chown, SYS_fchownat, SYS_lchown, SYS_link, SYS_linkat,
		SYS_symlink, SYS_symlinkat, SYS_socket, SYS_ptrace, SYS_setuid, SYS_setgid,
	};
	enum { N = sizeof(deny) / sizeof(*deny) };
	struct sock_filter f[4 + 5 + 2 * N + 1];   /* arch, nr, tgkill, the list, allow */
	int k = 0;
	f[k++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
	f[k++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0);
	f[k++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
	f[k++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
	/* tgkill only at this process: abort() (stack protector, fortify, the allocator) uses it */
	f[k++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_tgkill, 0, 4);
	f[k++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0]));
	f[k++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned)getpid(), 1, 0);
	f[k++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
	f[k++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
	for (int i = 0; i < N; i++) {
		f[k++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned)deny[i], 0, 1);
		f[k++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
	}
	f[k++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
	struct sock_fprog prog = { (unsigned short)k, f };
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog)) {
		perror("fuzz: seccomp");
		_exit(3);
	}
}

/* ---------------- corpus and mutation ---------------- */

struct shared {
	unsigned long execs, found, crashes;
	size_t len;
	uint8_t data[HARD_MAX];
};
static struct shared *sh;
static uint8_t *q_data[MAXQ];
static size_t q_len[MAXQ], nq;
static uint64_t rs;

static uint64_t rnd(void)
{
	rs ^= rs << 13;
	rs ^= rs >> 7;
	rs ^= rs << 17;
	return rs;
}

static uint64_t fnv(const uint8_t *d, size_t n)
{
	uint64_t h = 1469598103934665603ULL;
	for (size_t i = 0; i < n; i++)
		h = (h ^ d[i]) * 1099511628211ULL;
	return h;
}

static void *raw(size_t n)   /* driver memory: outside the guard allocator */
{
	void *p = mmap(NULL, n ? n : 1, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED)
		abort();
	return p;
}

static void q_add(const uint8_t *d, size_t n)
{
	if (nq == MAXQ)
		return;
	q_data[nq] = raw(n);
	memcpy(q_data[nq], d, n);
	q_len[nq++] = n;
}

static void save(const char *dir, const char *kind, const uint8_t *d, size_t n)
{
	char p[4096];
	snprintf(p, sizeof(p), "%s/%s%016llx", dir, kind, (unsigned long long)fnv(d, n));
	int fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0644);
	if (fd < 0)
		return;   /* already there */
	ssize_t r = write(fd, d, n);
	(void)r;
	close(fd);
}

static void load_dir(const char *dir)
{
	DIR *dp = opendir(dir);
	struct dirent *e;
	static uint8_t buf[HARD_MAX];
	while (dp && (e = readdir(dp))) {
		char p[4096];
		if (e->d_name[0] == '.')
			continue;
		snprintf(p, sizeof(p), "%s/%s", dir, e->d_name);
		int fd = open(p, O_RDONLY);
		if (fd < 0)
			continue;
		ssize_t n = read(fd, buf, fuzz_max_len < HARD_MAX ? fuzz_max_len : HARD_MAX);
		close(fd);
		if (n >= 0)
			q_add(buf, (size_t)n);
	}
	if (dp)
		closedir(dp);
	if (!nq)
		q_add((const uint8_t *)"", 0);
}

static size_t mutate(uint8_t *b, size_t n, size_t max)
{
	static const int64_t interesting[] = { 0, 1, -1, 16, 32, 64, 100, 127, 128, 255, 256, 512,
		1000, 1024, 4096, 32767, 32768, 65535, 65536, 2147483647LL, -2147483648LL, 4294967295LL,
		4294967296LL, 9223372036854775807LL };
	size_t ndict = 0;
	while (fuzz_dict[ndict])
		ndict++;
	int ops = 1 << (rnd() % 5);
	for (int o = 0; o < ops; o++) {
		size_t pos = n ? rnd() % n : 0;
		switch (rnd() % 14) {
		case 0:
			if (n) b[pos] ^= (uint8_t)(1u << (rnd() % 8));
			break;
		case 1:
			if (n) b[pos] = (uint8_t)rnd();
			break;
		case 2: case 3: {   /* an interesting number, 1/2/4/8 bytes, either endianness */
			size_t w = (size_t)1 << (rnd() % 4);
			int64_t v = interesting[rnd() % (sizeof(interesting) / sizeof(*interesting))];
			if (n < w)
				break;
			pos = rnd() % (n - w + 1);
			for (size_t i = 0; i < w; i++)
				b[pos + (rnd() & 1 ? i : w - 1 - i)] = (uint8_t)(v >> (8 * i));
			break;
		}
		case 4: {   /* an ASCII number (text formats) */
			char num[32];
			int l = snprintf(num, sizeof(num), "%lld", (long long)interesting[rnd() % (sizeof(interesting) / sizeof(*interesting))]);
			if (n + (size_t)l <= max) {
				memmove(b + pos + l, b + pos, n - pos);
				memcpy(b + pos, num, (size_t)l);
				n += (size_t)l;
			}
			break;
		}
		case 5: case 6: {   /* delete a block */
			if (!n) break;
			size_t l = 1 + rnd() % (n - pos < 64 ? n - pos : 64);
			memmove(b + pos, b + pos + l, n - pos - l);
			n -= l;
			break;
		}
		case 7: {   /* duplicate a block (lines, fields) */
			if (!n) break;
			size_t from = rnd() % n, l = 1 + rnd() % (n - from < 256 ? n - from : 256);
			if (n + l > max) break;
			memmove(b + pos + l, b + pos, n - pos);
			memmove(b + pos, b + (from >= pos ? from + l : from), l);
			n += l;
			break;
		}
		case 8: case 9: case 10: {   /* a dictionary word, inserted or over the bytes */
			if (!ndict) break;
			const char *w = fuzz_dict[rnd() % ndict];
			size_t l = strlen(w);
			if (rnd() & 1) {
				if (n + l > max) break;
				memmove(b + pos + l, b + pos, n - pos);
				n += l;
			} else if (pos + l > n) {
				break;
			}
			memcpy(b + pos, w, l);
			break;
		}
		case 11: {   /* splice with another corpus entry */
			size_t j = rnd() % nq, cut = n ? rnd() % n : 0;
			size_t from = q_len[j] ? rnd() % q_len[j] : 0, l = q_len[j] - from;
			if (cut + l > max) l = max - cut;
			memcpy(b + cut, q_data[j] + from, l);
			n = cut + l;
			break;
		}
		case 12: {   /* a long run of one byte */
			size_t l = 1 + rnd() % 2048;
			uint8_t c = rnd() & 1 ? (uint8_t)rnd() : (n ? b[pos] : 'A');
			if (n + l > max) break;
			memmove(b + pos + l, b + pos, n - pos);
			memset(b + pos, c, l);
			n += l;
			break;
		}
		case 13:   /* cut the end */
			n = pos;
			break;
		}
	}
	return n;
}

static void run_one(const uint8_t *d, size_t n)
{
	in_target = 1;
	if (!setjmp(exit_jb))
		fuzz_one(d, n);
	in_target = 0;
}

static void worker(const char *corpus, unsigned batch)
{
	static uint8_t buf[HARD_MAX];
	size_t max = fuzz_max_len < HARD_MAX ? fuzz_max_len : HARD_MAX;
	rs = (uint64_t)time(NULL) ^ ((uint64_t)getpid() << 32) ^ (uint64_t)clock();
	if (!rs)
		rs = 88172645463325252ULL;
	load_dir(corpus);
	if (!getenv("FUZZ_VERBOSE")) {   /* the code's own messages (rejected inputs); repro shows them */
		int fd = open("/dev/null", O_WRONLY);
		if (fd >= 0) {
			dup2(fd, 1);
			dup2(fd, 2);
			close(fd);
		}
	}
	if (fuzz_init)
		fuzz_init();
	sandbox();
	for (unsigned it = 0; it < batch; it++) {
		size_t j = rnd() % nq, n = q_len[j];
		memcpy(buf, q_data[j], n);
		n = mutate(buf, n, max);
		sh->len = n;
		memcpy(sh->data, buf, n);
		memset(trace, 0, sizeof(trace));
		prev_loc = 0;
		alarm(5);
		run_one(buf, n);
		alarm(0);
		__atomic_fetch_add(&sh->execs, 1, __ATOMIC_RELAXED);
		if (new_coverage()) {
			q_add(buf, n);
			save(corpus, "c-", buf, n);
			__atomic_fetch_add(&sh->found, 1, __ATOMIC_RELAXED);
		}
	}
	_exit(0);
}

static int repro(int argc, char **argv)
{
	static uint8_t buf[HARD_MAX];
	if (fuzz_init)
		fuzz_init();
	sandbox();
	for (int i = 2; i < argc; i++) {
		int fd = open(argv[i], O_RDONLY);
		ssize_t n = fd < 0 ? -1 : read(fd, buf, HARD_MAX);
		if (fd >= 0)
			close(fd);
		if (n < 0) {
			perror(argv[i]);
			return 1;
		}
		fprintf(stderr, "fuzz: %s (%zd bytes)\n", argv[i], n);
		run_one(buf, (size_t)n);
	}
	fputs("fuzz: no crash\n", stderr);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc >= 3 && !strcmp(argv[1], "-r"))
		return repro(argc, argv);
	if (argc < 3) {
		fputs("usage: fuzz-<target> <corpus-dir> <out-dir> [seconds] | -r <file>...\n", stderr);
		return 2;
	}
	if (geteuid() == 0) {
		fputs("fuzz: not as root\n", stderr);
		return 2;
	}
	const char *corpus = argv[1], *out = argv[2];
	long secs = argc > 3 ? atol(argv[3]) : 600;
	unsigned batch = getenv("FUZZ_BATCH") ? (unsigned)atoi(getenv("FUZZ_BATCH")) : 500;
	mkdir(corpus, 0755);
	mkdir(out, 0755);
	virgin = mmap(NULL, MAPSZ, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	sh = mmap(NULL, sizeof(*sh), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (virgin == MAP_FAILED || sh == MAP_FAILED)
		return 1;
	time_t start = time(NULL), last = start;
	while (time(NULL) - start < secs) {
		pid_t pid = fork();
		if (pid < 0)
			return 1;
		if (pid == 0)
			worker(corpus, batch);
		int st;
		waitpid(pid, &st, 0);
		if (WIFSIGNALED(st) || (WIFEXITED(st) && WEXITSTATUS(st) != 0)) {
			char kind[32];
			int sig = WIFSIGNALED(st) ? WTERMSIG(st) : 0;
			if (WIFEXITED(st) && WEXITSTATUS(st) == 3)
				return 1;   /* the sandbox could not be set up */
			snprintf(kind, sizeof(kind), "%s-",
			         sig == SIGALRM ? "hang" : sig == SIGILL ? "ubsan" : sig == SIGSYS ? "syscall" :
			         sig == SIGSEGV ? "segv" : sig == SIGABRT ? "abort" : sig == SIGBUS ? "bus" : "exit");
			save(out, kind, sh->data, sh->len);
			sh->crashes++;
			fprintf(stderr, "fuzz: %s (signal %d), input of %zu bytes saved in %s\n", kind, sig, sh->len, out);
		}
		if (time(NULL) - last >= 30) {
			last = time(NULL);
			fprintf(stderr, "fuzz: %lds %lu execs (%lu/s), %lu new paths, %lu findings\n",
			        (long)(last - start), sh->execs, sh->execs / (unsigned long)(last - start ? last - start : 1),
			        sh->found, sh->crashes);
		}
	}
	fprintf(stderr, "fuzz: done: %lu execs, %lu new paths, %lu findings\n", sh->execs, sh->found, sh->crashes);
	return sh->crashes ? 1 : 0;
}

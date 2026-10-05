/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* install.c - partition, format, build and install the chosen packages, users, network */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "state.h"
#include "ui.h"

static struct state *S;
static char step_name[256];

/* ---------------- steps, failure ---------------- */

static void redraw(void)
{
	ui_progress("Installing", step_name, LOG);
}

static void step(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void step(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(step_name, sizeof(step_name), fmt, ap);
	va_end(ap);
	logf_("==> %s\n", step_name);
	redraw();
}

static bool mounted(const char *path)
{
	char *m = read_text("/proc/mounts"), *pat = xasprintf(" %s ", path);
	bool yes = m && strstr(m, pat);
	free(m);
	free(pat);
	return yes;
}

static void cleanup_mounts(void)
{
	static const char *sub[] = { "/dev/pts", "/dev", "/proc", "/sys", "/run", "/boot", "/home", "" };
	for (size_t i = 0; i < sizeof(sub) / sizeof(*sub); i++) {
		char *p = xasprintf("%s%s", TARGET, sub[i]);
		if (mounted(p)) {
			char *argv[] = { "umount", p, NULL };
			run(argv);
		}
		free(p);
	}
}

/* the last thing on screen must be the failure, never something that reads like success */
static _Noreturn void fail(const char *why)
{
	char *msg, *tail = NULL, *log = read_text(LOG);
	logf_("!! %s\n", why);
	if (log) {   /* the last lines of the log */
		int lines = 0;
		char *p = log + strlen(log);
		while (p > log && lines < 12)
			if (*--p == '\n')
				lines++;
		tail = p;
	}
	if (file_exists(TARGET "/var/log")) {
		char *dst = TARGET "/var/log/cig-install.log", *argv[] = { "cp", (char *)LOG, dst, NULL };
		if (run(argv) == 0)
			chmod(dst, 0600);
	}
	cleanup_mounts();
	msg = xasprintf("!! INSTALLATION FAILED at: %s\n!! /dev/%s is NOT bootable. Full log: %s\n\n%s\n\n"
	                "Last lines of the log:\n%s", step_name, S->disk, LOG, why, tail ? tail : "");
	ui_msg("INSTALLATION FAILED", msg);
	ui_end();
	printf("\n!! INSTALLATION FAILED at: %s\n!! /dev/%s is NOT bootable. Full log: %s\n", step_name, S->disk, LOG);
	exit(1);
}

#define RUN(...) do { \
		char *argv_[] = { __VA_ARGS__, NULL }; \
		if (run(argv_) != 0) \
			fail("command failed: " #__VA_ARGS__); \
	} while (0)

static void put_file(const char *path, const char *text, mode_t mode)
{
	FILE *f = fopen(path, "w");
	if (!f || fputs(text, f) == EOF || fclose(f) != 0)
		fail(xasprintf("cannot write %s: %s", path, strerror(errno)));
	if (chmod(path, mode) != 0)
		fail(xasprintf("cannot chmod %s", path));
}

static void mkdirs(const char *p)
{
	char *argv[] = { "mkdir", "-p", (char *)p, NULL };
	if (run(argv) != 0)
		fail(xasprintf("cannot create %s", p));
}

static char *fs_uuid(const char *dev)
{
	char *argv[] = { "blkid", (char *)dev, NULL }, *out = capture(argv), *u, *uuid = NULL;
	if (out && (u = strstr(out, " UUID=\""))) {
		u += 7;
		uuid = xstrdup(u);
		uuid[strcspn(uuid, "\"")] = '\0';
	}
	free(out);
	return uuid;
}

static void make_fs(const char *fs, const char *dev, const char *mount)
{
	const char *label = !strcmp(mount, "/") ? "root" : !strcmp(mount, "/home") ? "home" :
	                    !strcmp(mount, "/boot") ? "ESP" : !strcmp(mount, "swap") ? "swap" : "data";
	if (!strcmp(fs, "vfat"))
		RUN("mkfs.vfat", "-F", "32", "-n", (char *)label, (char *)dev);
	else if (!strcmp(fs, "ext4"))
		RUN("mkfs.ext4", "-F", "-q", "-L", (char *)label, (char *)dev);
	else if (!strcmp(fs, "swap"))
		RUN("mkswap", "-L", (char *)label, (char *)dev);
	else
		fail(xasprintf("no mkfs for %s", fs));
}

static char *cigbuild_pkgfile(const char *pkg, const char *cig_var)
{
	char *var = xasprintf("CIG_VAR=%s", cig_var);
	char *argv[] = { "env", var, S->cigbuild, "pkgfile", (char *)pkg, NULL }, *f = capture(argv);
	free(var);
	if (!f)
		fail(xasprintf("no package path for %s", pkg));
	return f;
}

/* ---------------- UEFI boot entry ---------------- */

/* Many laptops only boot internal disks through an NVRAM boot entry, not through the
 * fallback EFI/BOOT/BOOTX64.EFI: write one, as efibootmgr would. Not fatal: the fallback
 * stays. Load option: attributes, file path list length, description (UCS-2), then the
 * device path HD(partition, GPT GUID)/File(\EFI\cig\vmlinuz.efi)/End. */
#define EFI_GLOBAL "8be4df61-93ca-11d2-aa0d-00e098032b8c"
#define EFIVARS "/sys/firmware/efi/efivars"

static void put16(unsigned char **p, unsigned v) { *(*p)++ = v & 0xff; *(*p)++ = (v >> 8) & 0xff; }
static void put32(unsigned char **p, unsigned long v) { for (int i = 0; i < 4; i++) *(*p)++ = (v >> (8 * i)) & 0xff; }
static void put64(unsigned char **p, unsigned long long v) { for (int i = 0; i < 8; i++) *(*p)++ = (v >> (8 * i)) & 0xff; }
static void put_ucs2(unsigned char **p, const char *s) { do put16(p, (unsigned char)*s); while (*s++); }

/* "EE32C236-4DA2-..." -> the 16 bytes as stored (first three fields little-endian) */
static bool guid_bytes(const char *g, unsigned char out[16])
{
	static const int order[16] = { 3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15 };
	unsigned char raw[16];
	int n = 0;
	for (const char *c = g; *c && n < 16; c++) {
		if (*c == '-')
			continue;
		unsigned v;
		if (sscanf(c, "%2x", &v) != 1)
			return false;
		raw[n++] = (unsigned char)v;
		c++;
	}
	if (n != 16)
		return false;
	for (int i = 0; i < 16; i++)
		out[i] = raw[order[i]];
	return true;
}

static bool write_var(const char *name, const unsigned char *data, size_t len)
{
	char *path = xasprintf(EFIVARS "/%s-" EFI_GLOBAL, name);
	FILE *f = fopen(path, "wb");
	bool ok = f && fwrite(data, 1, len, f) == len;   /* efivarfs wants one write */
	if (f && fclose(f) != 0)
		ok = false;
	free(path);
	return ok;
}

static void efi_boot_entry(struct state *s, const struct part *esp)
{
	unsigned char guid[16], buf[512], *p = buf, *fpl, order[256];
	char *d = xasprintf("/dev/%s", s->disk), *n = xasprintf("%d", esp->num), *uuid, name[16];
	char *argv[] = { "sfdisk", "--part-uuid", d, n, NULL };
	int num = -1;

	if (!file_exists(EFIVARS "/BootOrder-" EFI_GLOBAL) && !file_exists(EFIVARS)) {
		logf_("    ! no EFI variables: no boot entry (the fallback path is used)\n");
		return;
	}
	if (!file_exists(EFIVARS "/BootOrder-" EFI_GLOBAL)) {
		char *m[] = { "mount", "-t", "efivarfs", "efivarfs", EFIVARS, NULL };
		run(m);
	}
	uuid = capture(argv);
	free(d);
	free(n);
	if (!uuid || !guid_bytes(uuid, guid)) {
		logf_("    ! cannot read the ESP's partition GUID: no boot entry\n");
		free(uuid);
		return;
	}
	free(uuid);
	for (int i = 0; i < 0x1000 && num < 0; i++) {   /* a free Boot#### */
		char *v = xasprintf(EFIVARS "/Boot%04X-" EFI_GLOBAL, i);
		if (!file_exists(v))
			num = i;
		free(v);
	}
	if (num < 0)
		return;

	put32(&p, 7);                       /* efivarfs: NV | BS | RT */
	put32(&p, 1);                       /* LOAD_OPTION_ACTIVE */
	unsigned char *lenpos = p;
	put16(&p, 0);                       /* FilePathListLength, filled in below */
	put_ucs2(&p, "cig");
	fpl = p;
	*p++ = 4; *p++ = 1; put16(&p, 42);  /* hard drive media device path */
	put32(&p, (unsigned long)esp->num);
	put64(&p, esp->pstart);
	put64(&p, esp->psize);
	memcpy(p, guid, 16);
	p += 16;
	*p++ = 2;                           /* GPT */
	*p++ = 2;                           /* signature is a GUID */
	const char *file = "\\EFI\\cig\\vmlinuz.efi";
	*p++ = 4; *p++ = 4; put16(&p, (unsigned)(4 + 2 * (strlen(file) + 1)));
	put_ucs2(&p, file);
	*p++ = 0x7f; *p++ = 0xff; put16(&p, 4);   /* end of the device path */
	unsigned fl = (unsigned)(p - fpl);
	lenpos[0] = fl & 0xff;
	lenpos[1] = (fl >> 8) & 0xff;

	snprintf(name, sizeof(name), "Boot%04X", num);
	if (!write_var(name, buf, (size_t)(p - buf))) {
		logf_("    ! the firmware did not accept a boot entry (the fallback path is used)\n");
		return;
	}
	/* first in BootOrder (attributes, then 16-bit entry numbers) */
	char *op = xasprintf(EFIVARS "/BootOrder-" EFI_GLOBAL);
	FILE *f = fopen(op, "rb");
	size_t olen = f ? fread(order, 1, sizeof(order), f) : 0;
	if (f)
		fclose(f);
	free(op);
	unsigned char nb[260], *q = nb;
	put32(&q, 7);
	put16(&q, (unsigned)num);
	for (size_t i = 4; i + 1 < olen && q - nb < (long)sizeof(nb) - 2; i += 2)
		if ((order[i] | order[i + 1] << 8) != num) {
			*q++ = order[i];
			*q++ = order[i + 1];
		}
	if (!write_var("BootOrder", nb, (size_t)(q - nb)))
		logf_("    ! could not put the boot entry first in BootOrder\n");
	logf_("boot entry %s \"cig\" -> \\EFI\\cig\\vmlinuz.efi on partition %d\n", name, esp->num);
}

/* ---------------- the install ---------------- */

void do_install(struct state *s)
{
	char dev[96], *DEV_ESP = NULL, *DEV_ROOT = NULL, *DEV_HOME = NULL, *DEV_SWAP = NULL;
	const char *FS_ROOT = "", *FS_HOME = "";
	int N_ROOT = 0;
	S = s;
	run_tick = redraw;
	put_file(LOG, "", 0600);

	/* ---- partitioning ---- */
	step("Partitioning /dev/%s", s->disk);
	cleanup_mounts();
	{
		char *m = read_text("/proc/mounts"), *pat = xasprintf("/dev/%s", s->disk);
		bool busy = false;
		for (char *l = m; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : l + strlen(l))
			if (!strncmp(l, pat, strlen(pat)))
				busy = true;
		free(m);
		free(pat);
		if (busy)
			fail("the disk has mounted partitions; unmount them first");
	}
	if (layout_place(&s->lay))
		fail("the partition layout does not fit the disk");
	{
		char *script = table_script(&s->lay), *d = xasprintf("/dev/%s", s->disk);
		logf_("%s", script);
		char *wipe = s->lay.wipe ? "always" : "never";   /* kept partitions are never wiped */
		char *argv[] = { "sfdisk", "--wipe", wipe, "--wipe-partitions", wipe, d, NULL };
		if (run_input(argv, script) != 0)
			fail("sfdisk could not write the partition table");
		free(script);
		free(d);
		sleep(2);
		char *mdev[] = { "mdev", "-s", NULL };
		run(mdev);
	}

	/* ---- formatting ---- */
	step("Formatting");
	for (int i = 0; i < s->lay.n; i++) {
		struct part *p = &s->lay.p[i];
		part_dev(s->disk, p->num, dev, sizeof(dev));
		if (!strcmp(p->mount, "/")) {
			DEV_ROOT = xstrdup(dev);
			N_ROOT = p->num;
			FS_ROOT = eff_fs(p);
		} else if (!strcmp(p->mount, "/home")) {
			DEV_HOME = xstrdup(dev);
			FS_HOME = eff_fs(p);
		} else if (!strcmp(p->mount, "/boot")) {
			DEV_ESP = xstrdup(dev);
		} else if (!strcmp(p->mount, "swap")) {
			DEV_SWAP = xstrdup(dev);
		}
		if (p->format)
			make_fs(p->mkfs, dev, p->mount);
	}
	if (!DEV_ROOT || !DEV_ESP)
		fail("no / or /boot partition");

	/* unique IDs: labels are not unique when several cig disks are attached */
	char *U_ESP = fs_uuid(DEV_ESP), *U_ROOT = fs_uuid(DEV_ROOT);
	char *U_HOME = DEV_HOME ? fs_uuid(DEV_HOME) : NULL, *U_SWAP = DEV_SWAP ? fs_uuid(DEV_SWAP) : NULL;
	char *PU_ROOT;
	{
		char *d = xasprintf("/dev/%s", s->disk), *n = xasprintf("%d", N_ROOT);
		char *argv[] = { "sfdisk", "--part-uuid", d, n, NULL };
		PU_ROOT = capture(argv);
		free(d);
		free(n);
	}
	logf_("+ ids: esp=%s root=%s home=%s swap=%s root-partuuid=%s\n", U_ESP ? U_ESP : "",
	      U_ROOT ? U_ROOT : "", U_HOME ? U_HOME : "", U_SWAP ? U_SWAP : "", PU_ROOT ? PU_ROOT : "");
	if (!U_ESP || !U_ROOT || !PU_ROOT || !*PU_ROOT || (DEV_HOME && !U_HOME) || (DEV_SWAP && !U_SWAP))
		fail("could not read the partition IDs");

	/* ---- mounting, base layout ---- */
	step("Mounting");
	mkdirs(TARGET);
	RUN("mount", "-t", (char *)FS_ROOT, DEV_ROOT, TARGET);
	mkdirs(TARGET "/boot");
	mkdirs(TARGET "/home");
	RUN("mount", "-t", "vfat", DEV_ESP, TARGET "/boot");
	if (DEV_HOME)
		RUN("mount", "-t", (char *)FS_HOME, DEV_HOME, TARGET "/home");

	step("Base layout");
	{
		static const char *dirs[] = { "usr/bin", "usr/lib", "usr/sbin", "etc/cig", "var/log", "var/tmp",
		                              "dev", "proc", "sys", "run", "tmp", "root" };
		for (size_t i = 0; i < sizeof(dirs) / sizeof(*dirs); i++) {
			char *p = xasprintf("%s/%s", TARGET, dirs[i]);
			mkdirs(p);
			free(p);
		}
		if (symlink("usr/bin", TARGET "/bin") || symlink("usr/lib", TARGET "/lib") ||
		    symlink("usr/sbin", TARGET "/sbin"))
			fail("cannot create /bin, /lib, /sbin");
		chmod(TARGET "/tmp", 01777);
		chmod(TARGET "/var/tmp", 01777);
		chmod(TARGET "/root", 0750);
		put_file(TARGET "/etc/passwd", "root:x:0:0:root:/root:/bin/bash\n"
		                               "nobody:x:65534:65534:nobody:/:/bin/false\n", 0644);
		put_file(TARGET "/etc/group", "root:x:0:\ntty:x:5:\nwheel:x:10:\naudio:x:11:\nvideo:x:12:\n"
		                              "input:x:24:\nusers:x:100:\nnogroup:x:65534:\n", 0644);
		put_file(TARGET "/etc/shadow", "root:!:20000:0:99999:7:::\nnobody:!:20000:0:99999:7:::\n", 0600);
		char *t = xasprintf("%s\n", s->host);
		put_file(TARGET "/etc/hostname", t, 0644);
		free(t);
		t = xasprintf("127.0.0.1 localhost %s\n::1       localhost %s\n", s->host, s->host);
		put_file(TARGET "/etc/hosts", t, 0644);
		free(t);
		put_file(TARGET "/etc/resolv.conf", "", 0644);

		char *fstab = xasprintf(
			"# device                                   mount  type   options                                dump pass\n"
			"%-42s %-6s %-6s %-38s 0    1\n", xasprintf("UUID=%s", U_ROOT), "/", FS_ROOT, "defaults,noatime");
		if (DEV_HOME)
			fstab = xasprintf("%s%-42s %-6s %-6s %-38s 0    2\n", fstab, xasprintf("UUID=%s", U_HOME),
			                  "/home", FS_HOME, "defaults,noatime,nodev,nosuid");
		fstab = xasprintf("%s%-42s /boot  vfat   noauto,nodev,nosuid,noexec,umask=0077  0    0\n",
		                  fstab, xasprintf("UUID=%s", U_ESP));
		if (DEV_SWAP)
			fstab = xasprintf("%s%-42s %-6s %-6s %-38s 0    0\n", fstab, xasprintf("UUID=%s", U_SWAP),
			                  "none", "swap", "sw");
		fstab = xasprintf("%stmpfs                                      /tmp   tmpfs  "
		                  "nosuid,nodev,noexec,mode=1777          0    0\n", fstab);
		put_file(TARGET "/etc/fstab", fstab, 0644);
		/* no boot entries yet: boot via EFI/BOOT/BOOTX64.EFI */
		put_file(TARGET "/etc/cig/efi-fallback", "", 0644);
	}

	/* hardware choices for the builds below */
	RUN("cp", WORKDIR "/lsmod", TARGET "/etc/cig/lsmod.install");
	{
		char *list = xstrdup("");
		int count = 0;
		for (int i = 0; i < s->ndrv; i++) {
			if (!s->drvs[i].on)
				continue;
			char *copy = xstrdup(s->drvs[i].files), *sv = NULL;
			for (char *f = strtok_r(copy, " ", &sv); f; f = strtok_r(NULL, " ", &sv)) {
				char *needle = xasprintf("\n%s\n", f), *hay = xasprintf("\n%s", list);
				if (!strstr(hay, needle)) {
					list = xasprintf("%s%s\n", list, f);
					count++;
				}
				free(needle);
				free(hay);
			}
			free(copy);
		}
		put_file(TARGET "/etc/cig/firmware.list", list, 0644);
		logf_("firmware: %d file(s)\n", count);
	}

	/* ---- packages ---- */
	/* Everything is built on the target disk, in the new system's own /var/cig. Nothing
	 * is copied in bulk: cigbuild takes a source (or, for prebuilt, a package) from the
	 * install media only when a chosen package needs it (checked by smoke audit below). */
	const char *media_var = getenv("CIG_VAR") ? getenv("CIG_VAR") : "/var/cig";
	char *media_sources = xasprintf("%s/sources", media_var), *media_pkgs = xasprintf("%s/pkgs", media_var);
	char *media_generic = xasprintf("%s/generic", media_var);
	setenv("CIG_VAR", TARGET "/var/cig", 1);
	mkdirs(TARGET "/var/cig/sources");
	mkdirs(TARGET "/var/cig/pkgs");
	mkdirs(TARGET "/var/cig/build");
	mkdirs(TARGET "/var/cig/logs");
	setenv("CIG_SOURCE_MIRROR", media_sources, 1);
	step("Preparing packages (%s)", s->compile_pkgs ? "compile" : "prebuilt");
	if (s->generic_kernel) {   /* the media's generic kernel (only looked up when chosen) */
		char *media_linux = cigbuild_pkgfile("linux", media_generic);
		RUN("cp", "-a", media_linux, TARGET "/var/cig/pkgs/");
		free(media_linux);
	}
	/* kernel and firmware are always made for this machine's selection */
	if (!s->generic_kernel) {
		char *f = cigbuild_pkgfile("linux", TARGET "/var/cig"), *root = xasprintf("PARTUUID=%s", PU_ROOT);
		unlink(f);
		step("Compiling the kernel for this machine (this takes a while)");
		setenv("CIG_KERNEL_PROFILE", "local", 1);
		setenv("CIG_KERNEL_LSMOD", WORKDIR "/lsmod", 1);
		setenv("CIG_ROOT", root, 1);
		RUN(s->cigbuild, "build", "linux");
		unsetenv("CIG_KERNEL_PROFILE");
		unsetenv("CIG_KERNEL_LSMOD");
		unsetenv("CIG_ROOT");
		free(f);
		free(root);
	}
	{
		char *f = cigbuild_pkgfile("linux-firmware", TARGET "/var/cig");
		unlink(f);
		free(f);
		step("Selecting firmware");
		setenv("CIG_FIRMWARE_LIST", TARGET "/etc/cig/firmware.list", 1);
		RUN(s->cigbuild, "build", "linux-firmware");
		unsetenv("CIG_FIRMWARE_LIST");
	}
	if (!s->compile_pkgs)
		setenv("CIG_PKG_MIRROR", media_pkgs, 1);   /* only after kernel and firmware */

	step("Installing packages");
	setenv("SMOKE_ROOT", TARGET, 1);
	{
		char *all = xstrdup(s->base);
		for (int i = 0; i < s->ncomp; i++)
			if (s->comps[i].on)
				all = xasprintf("%s %s", all, s->comps[i].name);
		char *sv = NULL;
		for (char *p = strtok_r(all, " ", &sv); p; p = strtok_r(NULL, " ", &sv)) {
			bool prebuilt = !s->compile_pkgs || !strcmp(p, "linux") || !strcmp(p, "linux-firmware");
			step("Installing packages: %s", p);
			RUN(s->smoke, "add", prebuilt ? "-p" : "-c", "-y", p);
		}
	}
	unsetenv("SMOKE_ROOT");
	unsetenv("CIG_SOURCE_MIRROR");
	unsetenv("CIG_PKG_MIRROR");
	RUN("sh", "-c", "rm -rf " TARGET "/var/cig/build/*");

	step("Running package setup inside the new system");
	RUN("mount", "--bind", "/dev", TARGET "/dev");
	{
		char *argv[] = { "mount", "-t", "devpts", "devpts", TARGET "/dev/pts", NULL };
		run(argv);
	}
	RUN("mount", "-t", "proc", "proc", TARGET "/proc");
	RUN("mount", "-t", "sysfs", "sysfs", TARGET "/sys");
	RUN("mount", "-t", "tmpfs", "tmpfs", TARGET "/run");
	{
		char *argv[] = { "env", "SMOKE_ROOT=" TARGET, s->smoke, "hooks", "--all", NULL };
		if (run(argv) != 0)
			logf_("    ! some package setup failed\n");
	}

	step("UEFI boot entry");
	for (int i = 0; i < s->lay.n; i++)
		if (!strcmp(s->lay.p[i].mount, "/boot"))
			efi_boot_entry(s, &s->lay.p[i]);

	/* the new system must contain exactly what its inventory says, nothing more */
	step("Checking the new system (smoke audit)");
	RUN("env", "SMOKE_ROOT=" TARGET, s->smoke, "audit", "--quick");

	/* every user must be able to reach the system (a wrong umask once made /usr 0750) */
	{
		static const char *dirs[] = { "", "/usr", "/usr/bin", "/usr/lib", "/usr/sbin", "/usr/share",
		                              "/usr/pkg", "/etc", "/var", NULL };
		for (int i = 0; dirs[i]; i++) {
			struct stat st;
			char *p = xasprintf("%s%s", TARGET, dirs[i]);
			if (stat(p, &st) == 0 && (st.st_mode & 0005) != 0005)
				fail(xasprintf("%s is not readable for all users (mode %o)", *dirs[i] ? dirs[i] : "/",
				               st.st_mode & 07777));
			free(p);
		}
	}

	step("Users");
	RUN("chroot", TARGET, "adduser", "-D", "-s", "/bin/bash", "-h", xasprintf("/home/%s", s->user), s->user);
	{
		static const char *groups[] = { "wheel", "audio", "video", "input", "users" };
		for (size_t i = 0; i < 5; i++)
			RUN("chroot", TARGET, "addgroup", s->user, (char *)groups[i]);
		char *in = xasprintf("%s:%s\n", s->user, s->userpass);
		char *argv[] = { "chroot", TARGET, "chpasswd", "-c", "sha512", NULL };
		if (run_input(argv, in) != 0)
			fail("cannot set the user's password");
		memset(in, 0, strlen(in));
		free(in);
		if (!s->root_lock) {
			in = xasprintf("root:%s\n", s->rootpass);
			if (run_input(argv, in) != 0)
				fail("cannot set the root password");
			memset(in, 0, strlen(in));
			free(in);
		}
		char *ida[] = { "chroot", TARGET, "id", "-u", s->user, NULL }, *idg[] = { "chroot", TARGET, "id", "-g", s->user, NULL };
		char *uid = capture(ida), *gid = capture(idg);
		if (!uid || !gid)
			fail("cannot find the new user");
		char *home = xasprintf("%s/home/%s", TARGET, s->user), *own = xasprintf("%s:%s", uid, gid);
		RUN("chown", "-R", own, home);
		chmod(home, 0700);
	}

	step("Network");
	mkdirs(TARGET "/etc/service");
	if (file_exists("/sys/class/net/eth0") && file_exists(TARGET "/etc/sv/udhcpc-eth0"))
		RUN("ln", "-sfn", "/etc/sv/udhcpc-eth0", TARGET "/etc/service/udhcpc-eth0");
	if (file_exists("/sys/class/net/wlan0") && file_exists(TARGET "/usr/sbin/wpa_supplicant")) {
		RUN("ln", "-sfn", "/etc/sv/wpa_supplicant", TARGET "/etc/service/wpa_supplicant");
		RUN("ln", "-sfn", "/etc/sv/udhcpc-wlan0", TARGET "/etc/service/udhcpc-wlan0");
		if (*s->ssid) {   /* the passphrase goes through stdin: never in a command line or the log */
			char *in = xasprintf("%s\n", s->psk);
			char *argv[] = { "chroot", TARGET, "wpa_passphrase", s->ssid, NULL };
			char *net = capture_input(argv, in);
			memset(in, 0, strlen(in));
			free(in);
			/* optional: a WiFi network that can't be set up is a warning, never a failed
			 * install (everything that boots the system is done by now) */
			FILE *f = net ? fopen(TARGET "/etc/wpa_supplicant/wpa_supplicant.conf", "a") : NULL;
			for (char *l = net, *e; f && l && *l; l = e ? e + 1 : NULL) {
				e = strchr(l, '\n');
				if (e)
					*e = '\0';
				if (!strstr(l, "#psk="))   /* not the passphrase in clear text */
					fprintf(f, "%s\n", l);
			}
			if (!net || !f || fclose(f) != 0) {
				logf_("    ! the WiFi network could not be set up\n");
				snprintf(s->warnings + strlen(s->warnings), sizeof(s->warnings) - strlen(s->warnings),
				         "The WiFi network \"%s\" could not be set up. After the first boot, as root:\n"
				         "  wpa_passphrase \"<network>\" >> /etc/wpa_supplicant/wpa_supplicant.conf\n", s->ssid);
			}
			if (net) {
				memset(net, 0, strlen(net));
				free(net);
			}
		}
	}

	step("Finishing");
	RUN("cp", (char *)LOG, TARGET "/var/log/cig-install.log");
	chmod(TARGET "/var/log/cig-install.log", 0600);
	sync();
	cleanup_mounts();
	run_tick = NULL;
}

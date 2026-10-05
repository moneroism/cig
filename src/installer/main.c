/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/*
 * cig-install - install cig onto a disk. Run as root on a running cig system
 * (the install media, or for testing a VM with a second, empty disk).
 *
 * One main menu shows every section with its current value; Enter edits a
 * section, Install is at the bottom. Nothing is written to any disk before
 * the final confirmation (typing the disk name).
 */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "state.h"
#include "ui.h"

static bool valid_name(const char *s, bool user)
{
	size_t n = strlen(s);
	if (!n || n > (user ? 32 : 63))
		return false;
	for (size_t i = 0; i < n; i++) {
		char c = s[i];
		bool ok = user ? ((c >= 'a' && c <= 'z') || c == '_' || (i && ((c >= '0' && c <= '9') || c == '-')))
		               : ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
		                  (i && c == '-'));
		if (!ok)
			return false;
	}
	return true;
}

/* a password, typed twice */
static bool password(const char *title, const char *who, char *out, size_t n)
{
	char a[256] = "", b[256] = "";
	for (;;) {
		char *q = xasprintf("Password for %s:", who);
		bool ok = ui_input(title, q, a, sizeof(a), true);
		free(q);
		if (!ok)
			return false;
		if (!*a) {
			ui_msg(title, "The password can't be empty.");
			continue;
		}
		if (!ui_input(title, "The same password again:", b, sizeof(b), true))
			return false;
		if (!strcmp(a, b))
			break;
		ui_msg(title, "The passwords did not match.");
	}
	snprintf(out, n, "%s", a);
	memset(a, 0, sizeof(a));
	memset(b, 0, sizeof(b));
	return true;
}

static void identity_screen(struct state *s)
{
	char buf[64];
	snprintf(buf, sizeof(buf), "%s", s->host);
	if (!ui_input("Identity", "Hostname (letters, digits, dashes):", buf, sizeof(buf), false))
		return;
	if (!valid_name(buf, false)) {
		ui_msg("Identity", "A hostname is letters, digits and dashes, not starting with a dash.");
		return;
	}
	snprintf(s->host, sizeof(s->host), "%s", buf);
	snprintf(buf, sizeof(buf), "%s", s->user);
	if (!ui_input("Identity", "Your user name (lowercase letters, digits, - and _):", buf, sizeof(buf), false))
		return;
	if (!valid_name(buf, true)) {
		ui_msg("Identity", "A user name starts with a lowercase letter or _, then letters, digits, - or _.");
		return;
	}
	snprintf(s->user, sizeof(s->user), "%.32s", buf);
	if (!password("Identity", s->user, s->userpass, sizeof(s->userpass)))
		return;
	static const char *const modes[] = { "locked: admin tasks only through doas (recommended)",
	                                     "with its own password" };
	int sel = s->root_lock ? 0 : 1;
	int c = ui_menu("Root account", "The user is in: wheel (doas), audio, video, input, users.", modes, NULL, 2, &sel);
	if (c == 1 && password("Root account", "root", s->rootpass, sizeof(s->rootpass)))
		s->root_lock = false;
	else if (c == 0)
		s->root_lock = true;
}

static void components_screen(struct state *s)
{
	const char **items = xmalloc((size_t)(s->ncomp ? s->ncomp : 1) * sizeof(char *));
	bool *on = xmalloc((size_t)(s->ncomp ? s->ncomp : 1) * sizeof(bool));
	for (int i = 0; i < s->ncomp; i++) {
		items[i] = xasprintf("%-9s %s", s->comps[i].group, *s->comps[i].desc ? s->comps[i].desc : s->comps[i].name);
		on[i] = s->comps[i].on;
	}
	char *text = xasprintf("Always installed: %s\nNot available yet: ALSA sound, PipeWire, Bluetooth, wmenu", s->base);
	ui_checklist("Components", text, items, on, s->ncomp);
	for (int i = 0; i < s->ncomp; i++) {
		s->comps[i].on = on[i];
		free((char *)items[i]);
	}
	free(items);
	free(on);
	free(text);
}

static void hardware_screen(struct state *s)
{
	if (s->ndrv) {
		const char **items = xmalloc((size_t)s->ndrv * sizeof(char *));
		bool *on = xmalloc((size_t)s->ndrv * sizeof(bool));
		for (int i = 0; i < s->ndrv; i++) {
			items[i] = xasprintf("%-12s %s", s->drvs[i].name, s->drvs[i].files);
			on[i] = s->drvs[i].on;
		}
		ui_checklist("Hardware: firmware",
		             "Firmware for the drivers this machine uses (never CPU microcode).\n"
		             "Drivers without their firmware may not work.", items, on, s->ndrv);
		for (int i = 0; i < s->ndrv; i++) {
			s->drvs[i].on = on[i];
			free((char *)items[i]);
		}
		free(items);
		free(on);
	}
	if (file_exists("/sys/class/net/wlan0") &&
	    ui_yesno("Hardware: WiFi", "Set up a WiFi network for the new system? (WPA2/WPA3-Personal)", !!*s->ssid)) {
		char ssid[64];
		snprintf(ssid, sizeof(ssid), "%s", s->ssid);
		if (ui_input("Hardware: WiFi", "Network name (SSID):", ssid, sizeof(ssid), false) && *ssid &&
		    password("Hardware: WiFi", ssid, s->psk, sizeof(s->psk)))
			snprintf(s->ssid, sizeof(s->ssid), "%s", ssid);
	} else if (!file_exists("/sys/class/net/wlan0")) {
		ui_msg("Hardware", s->ndrv ? "No WiFi device found." : "No driver of this machine requests firmware.\nNo WiFi device found.");
	}
}

/* the root= built into the media's generic kernel (in <CIG_VAR>/generic, apart from the
 * media system's own kernel): a generic kernel must find root by name */
static bool generic_kernel_ok(struct state *s)
{
	const char *mv = getenv("CIG_VAR") ? getenv("CIG_VAR") : "/var/cig";
	char *var = xasprintf("CIG_VAR=%s/generic", mv);
	char *argv[] = { "env", var, s->cigbuild, "pkgfile", "linux", NULL }, *pkg = capture(argv), *root = NULL;
	free(var);
	if (pkg && file_exists(pkg)) {
		char *sh[] = { "sh", "-c",
			"f=$(tar -tzf \"$0\" | grep '/vmlinuz$' | head -n1) && "
			"tar -xOzf \"$0\" \"$f\" | grep -ao 'root=[^ ]*' | head -n1", pkg, NULL };
		root = capture(sh);
	}
	bool ok = root && !strcmp(root, "root=PARTLABEL=cig-root");
	if (!ok) {
		char *m = xasprintf(pkg && file_exists(pkg)
		                    ? "The kernel on the install media is not generic: it was built for one installation "
		                      "(%s) and would not find this system's root.\n\nIt will be compiled for this machine instead."
		                    : "The install media has no prebuilt kernel%s; it will be compiled.",
		                    root ? root : pkg && file_exists(pkg) ? "no root= found" : "");
		ui_msg("Kernel", m);
		free(m);
	}
	free(pkg);
	free(root);
	return ok;
}

static void build_screen(struct state *s)
{
	static const char *const pk[] = { "compile everything on this machine from verified source (hours)",
	                                  "use the prebuilt packages from the install media (fast)" };
	static const char *const kn[] = { "compile for this machine: only its drivers, a unique module signing key",
	                                  "generic kernel from the install media" };
	int sel = s->compile_pkgs ? 0 : 1;
	int c = ui_menu("Build: packages", NULL, pk, NULL, 2, &sel);
	if (c >= 0)
		s->compile_pkgs = c == 0;
	sel = s->generic_kernel ? 1 : 0;
	c = ui_menu("Build: kernel", "Compiling takes 20-60 minutes.", kn, NULL, 2, &sel);
	if (c == 0) {
		s->generic_kernel = false;
	} else if (c == 1) {
		s->generic_kernel =
			ui_yesno("Build: kernel",
			         "WARNING: the generic kernel contains drivers for all common hardware (much larger "
			         "attack surface), and its modules were signed with a key used for every copy of the "
			         "install media, not one unique to this machine.\n\nUse the generic kernel anyway?", false) &&
			generic_kernel_ok(s);
	}
}

/* the chosen components (base packages are always installed) */
static char *selected(const struct state *s)
{
	char *out = xstrdup("base");
	for (int i = 0; i < s->ncomp; i++)
		if (s->comps[i].on) {
			char *n = xasprintf("%s %s", out, s->comps[i].name);
			free(out);
			out = n;
		}
	return out;
}

static char *disk_value(struct state *s)
{
	if (!*s->disk)
		return xstrdup("not chosen");
	if (!s->layout_ok)
		return xasprintf("/dev/%s: layout not finished", s->disk);
	char *out = xasprintf("/dev/%s: %s", s->disk, s->lay.wipe ? "erase disk; " : "");
	layout_place(&s->lay);
	for (int i = 0; i < s->lay.n; i++) {
		struct part *p = &s->lay.p[i];
		if (!*p->mount && !p->isnew)
			continue;
		char *sz = size_h((unsigned long long)p->psize * s->lay.sect);
		char *n = xasprintf("%s%s %s %s, ", out, *p->mount ? p->mount : "unused", sz,
		                    p->isnew ? "new" : p->format ? "format" : "keep");
		free(out);
		free(sz);
		out = n;
	}
	size_t l = strlen(out);
	if (l > 2 && !strcmp(out + l - 2, ", "))
		out[l - 2] = '\0';
	return out;
}

/* what will be lost, then type the disk name */
static bool confirm(struct state *s)
{
	char *text = s->lay.wipe ? xasprintf("ALL DATA ON /dev/%s WILL BE ERASED.", s->disk)
	                         : xasprintf("The partition table of /dev/%s will be rewritten.", s->disk);
	for (int o = 0; o < s->lay.norig; o++) {
		bool kept = false;
		for (int i = 0; i < s->lay.n; i++)
			kept |= !s->lay.p[i].isnew && s->lay.p[i].num == s->lay.orig[o].num;
		if (!kept)
			text = xasprintf("%s\n  DELETED (data lost):   partition %d %s \"%s\"", text, s->lay.orig[o].num,
			                 s->lay.orig[o].fs, s->lay.orig[o].name);
	}
	for (int i = 0; i < s->lay.n; i++) {
		struct part *p = &s->lay.p[i];
		if (p->isnew)
			continue;
		if (p->format)
			text = xasprintf("%s\n  FORMATTED (data lost): partition %d %s \"%s\"", text, p->num, p->fs, p->name);
		else if (*p->mount)
			text = xasprintf("%s\n  kept as %s: partition %d %s", text, p->mount, p->num, p->fs);
		if (!strcmp(p->mount, "/boot"))
			text = xasprintf("%s\n  note: EFI/BOOT/BOOTX64.EFI on the kept ESP will be replaced by cig's kernel", text);
	}
	text = xasprintf("%s\n\nType the disk name (%s) to install:", text, s->disk);
	char buf[64] = "";
	bool ok = ui_input("Install", text, buf, sizeof(buf), false) && !strcmp(buf, s->disk);
	if (!ok)
		ui_msg("Install", "Not confirmed. Nothing was changed.");
	return ok;
}

static void settings(struct state *s)
{
	char exe[PATH_MAX];
	/* cigbuild, smoke, packages: next to the installer in the repository (src/installer),
	 * otherwise the shared /usr/share/cig */
	snprintf(s->share, sizeof(s->share), "/usr/share/cig");
	if (realpath("/proc/self/exe", exe)) {
		char *slash = strrchr(exe, '/');
		if (slash) {
			*slash = '\0';
			char *repo = xasprintf("%s/../../cigbuild", exe), real[PATH_MAX];
			if (access(repo, X_OK) == 0 && realpath(repo, real)) {
				*strrchr(real, '/') = '\0';   /* the repository itself */
				snprintf(s->share, sizeof(s->share), "%s", real);
			}
			free(repo);
		}
	}
	s->cigbuild = xasprintf("%s/cigbuild", s->share);
	s->smoke = xasprintf("%s/smoke", s->share);
	char *vp = xasprintf("%s/VERSION", s->share);
	s->version = read_text(vp);
	free(vp);
	if (!s->version)
		s->version = xstrdup("unknown");
	s->version[strcspn(s->version, "\n")] = '\0';
	snprintf(s->host, sizeof(s->host), "cig");
	s->root_lock = true;
	s->compile_pkgs = true;
	s->sep_home = true;
	s->root_g = 40;
}

static void preflight(struct state *s)
{
	static const char *tools[] = { "sfdisk", "blkid", "mkfs.vfat", "mkfs.ext4", "mkswap", "chpasswd",
	                               "adduser", "chroot", "tar", NULL };
	if (geteuid() != 0 && !getenv("CIG_INSTALL_DEMO")) {
		fputs("cig-install: run as root\n", stderr);
		exit(1);
	}
	if (!file_exists("/sys/firmware/efi") && !getenv("CIG_INSTALL_DEMO")) {
		fputs("cig-install: this machine did not boot in UEFI mode; cig needs UEFI\n", stderr);
		exit(1);
	}
	for (int i = 0; tools[i]; i++) {
		char *argv[] = { "sh", "-c", "command -v \"$0\" >/dev/null", (char *)tools[i], NULL };
		if (run(argv) != 0 && !getenv("CIG_INSTALL_DEMO")) {
			fprintf(stderr, "cig-install: missing tool: %s\n", tools[i]);
			exit(1);
		}
	}
	if (access(s->cigbuild, X_OK) || access(s->smoke, X_OK)) {
		fprintf(stderr, "cig-install: cigbuild/smoke not found in %s\n", s->share);
		exit(1);
	}
	mkdir(WORKDIR, 0700);
	/* long builds: keep the console from blanking while the installer runs */
	fputs("\033[9;0]", stdout);
	fflush(stdout);
}

int main(void)
{
	static struct state s;
	umask(022);   /* system files are world-readable, whatever the caller's umask (cig's profile: 027) */
	settings(&s);
	if (getenv("CIG_INSTALL_DEMO"))
		LOG = WORKDIR "/install.log";   /* demo/testing: never touches the real log */
	preflight(&s);
	s.ncomp = load_components(s.share, &s.comps, &s.base);
	s.ndrv = detect_hardware(&s.drvs, WORKDIR "/lsmod");
	ui_init();

	int sel = 0;
	for (;;) {
		char *v[8];
		char *pk = selected(&s), *fw = xstrdup("");
		for (int i = 0; i < s.ndrv; i++)
			if (s.drvs[i].on) {
				char *n = xasprintf("%s%s ", fw, s.drvs[i].name);
				free(fw);
				fw = n;
			}
		v[0] = disk_value(&s);
		v[1] = *s.user ? xasprintf("host %s, user %s, root %s", s.host, s.user, s.root_lock ? "locked" : "with password")
		               : xstrdup("not set");
		v[2] = pk;
		v[3] = xasprintf("firmware: %s; WiFi: %s", *fw ? fw : "none", *s.ssid ? s.ssid : "not set");
		v[4] = xstrdup("defaults (optional layers not available yet)");
		v[5] = xasprintf("packages %s, kernel %s", s.compile_pkgs ? "compiled here" : "prebuilt",
		                 s.generic_kernel ? "generic" : "compiled for this machine");
		v[6] = xstrdup("");
		v[7] = xstrdup("");
		static const char *const items[] = { "Disk", "Identity", "Components", "Hardware", "Security",
		                                     "Build", "Install", "Quit without changes" };
		char *title = xasprintf("cig %s - choose a section, Install when everything is set", s.version);
		int c = ui_menu(title, NULL, items, (const char *const *)v, 8, &sel);
		free(title);
		for (int i = 0; i < 8; i++)
			free(v[i]);
		free(fw);
		switch (c) {
		case 0: disk_screen(&s); break;
		case 1: identity_screen(&s); break;
		case 2: components_screen(&s); break;
		case 3: hardware_screen(&s); break;
		case 4: ui_msg("Security", "Optional security layers (allowlisting, kernel-enforced execution "
		                           "control) come with cig 0.5. The defaults are already hardened."); break;
		case 5: build_screen(&s); break;
		case 6:
			if (!*s.disk || !s.layout_ok) {
				ui_msg("Install", "Choose the disk and finish its layout first.");
				break;
			}
			if (!*s.user || !*s.userpass) {
				ui_msg("Install", "Set your user name and password first (Identity).");
				break;
			}
			if (!confirm(&s))
				break;
			if (getenv("CIG_INSTALL_DEMO")) {
				ui_end();
				puts("demo: would install now");
				return 0;
			}
			do_install(&s);
			{
				char *m = xasprintf("cig %s is installed on /dev/%s.\n\nPower off, remove the install media, "
				                    "and boot from that disk.", s.version, s.disk);
				ui_msg("Installed", m);
				free(m);
			}
			ui_end();
			return 0;
		case 7: case -1:
			if (ui_yesno("Quit", "Quit without changes?", true)) {
				ui_end();
				puts("Nothing was changed.");
				return 0;
			}
			break;
		}
	}
}

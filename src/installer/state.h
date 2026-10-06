/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* state.h - everything the user chose, filled by the screens, used by the install */
#ifndef STATE_H
#define STATE_H

#include <stdbool.h>

#include "disk.h"
#include "sys.h"

#define TARGET "/mnt/cig-target"
#define WORKDIR "/tmp/cig-install"

struct state {
	char share[4096];         /* /usr/share/cig: cigbuild, smoke, packages */
	char *cigbuild, *smoke, *version;

	char disk[64];            /* chosen disk, "" = none yet */
	struct layout lay;
	bool layout_ok;
	bool sep_home;
	unsigned root_g, swap_g;  /* auto layout */

	char host[64], user[33];
	char userpass[256], rootpass[256];
	bool root_lock;

	struct comp *comps;
	int ncomp;
	char *base;               /* base packages, always installed */

	struct drv *drvs;
	int ndrv;
	char ssid[64], psk[128];
	enum dns { DNS_TLS, DNS_RECURSIVE, DNS_DHCP } dns;   /* DNS_TLS (0) is the default */

	bool compile_pkgs;        /* compile everything (default) or prebuilt */
	char warnings[1024];      /* optional steps that did not work (shown at the end) */
	bool generic_kernel;      /* only if the media kernel finds root by name */
};

/* the DNS choice as a short value for the menu */
const char *dns_value(const struct state *s);
bool comp_on(const struct state *s, const char *name);

void do_install(struct state *s);   /* returns only on success */
void disk_screen(struct state *s);
char *size_h(unsigned long long bytes);   /* 512M / 40G / 1.8T */

#endif

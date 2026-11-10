/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* t_answers.c - the installer's --answers file (read_answers in src/installer/main.c) */
#define main cig_install_main
#include "../../src/installer/main.c"
#undef main
#include "fuzz.h"

const char *fuzz_dict[] = { "disk", "erase", "home", "root_size", "swap", "hostname", "user",
	"password", "root_password", "components", "firmware", "wifi_ssid", "wifi_psk", "dns",
	"compile", "kernel", " = ", "=", "yes", "no", "sda", "+labwc", "-wmenu", "+", "-", "tls",
	"recursive", "dhcp", "detected", "none", "local", "generic", "\n", "#", "\t", "\r", NULL };
size_t fuzz_max_len = 8192;

static struct comp comps[3] = { { "labwc", "desktop", "", false }, { "wmenu", "desktop", "", true },
                                { "bluez", "bluetooth", "", false } };

void fuzz_one(const uint8_t *data, size_t len)
{
	static struct state s;
	struct drv drvs[1] = { { "iwlwifi", NULL, 1, -1, true } };
	memset(&s, 0, sizeof(s));
	comps[0].on = false;
	comps[1].on = true;
	comps[2].on = false;
	s.comps = comps;
	s.ncomp = 3;
	s.drvs = drvs;
	s.ndrv = 1;
	s.root_lock = true;
	read_answers(&s, fuzz_file(data, len));
}

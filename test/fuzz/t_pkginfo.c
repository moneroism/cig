/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* t_pkginfo.c - smoke's .PKGINFO parser (parse_assignments in src/smoke/install.c); a
 * prebuilt package's .PKGINFO comes from outside the device */
#include "../../src/smoke/install.c"
#include "fuzz.h"

/* smoke's root (main.c): a folder that does not exist, so nothing on the host is read or written */
const char *ROOT = "/nonexistent-cig-fuzz", *PKGROOT = "/nonexistent-cig-fuzz/usr/pkg",
           *INV = "/nonexistent-cig-fuzz/usr/pkg/INVENTORY", *CIG_VAR = "/nonexistent-cig-fuzz/var",
           *CIG_REPO = "/nonexistent-cig-fuzz/repo", *CIGBUILD = "/nonexistent-cig-fuzz/cigbuild";

const char *fuzz_dict[] = { "name=", "version=", "rel=", "depends=", "config_files=", "link_dirs=",
	"copy_files=", "\"", "\n", "#", "=", "\\", NULL };
size_t fuzz_max_len = 16384;

void fuzz_one(const uint8_t *data, size_t len)
{
	char *text = malloc(len + 1);
	memcpy(text, data, len);
	text[len] = '\0';
	struct meta m = { 0 };
	char *rel = NULL;
	parse_assignments(text, &m, &rel);
	/* what read_meta does next with the fields */
	if (m.name && m.version && rel && valid_name(m.version) && valid_name(rel)) {
		char *v = xasprintf("%s-%s", m.version, rel);
		free(v);
	}
	free(rel);
	free_meta(&m);
	free(text);
}

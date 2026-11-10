/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* t_elf.c - smoke audit's ELF reader (elf_needed in src/smoke/audit.c): it opens every
 * program and library under /usr/pkg */
#include "../../src/smoke/audit.c"
#include "fuzz.h"

/* smoke's root (main.c): a folder that does not exist, so nothing on the host is read or written */
const char *ROOT = "/nonexistent-cig-fuzz", *PKGROOT = "/nonexistent-cig-fuzz/usr/pkg",
           *INV = "/nonexistent-cig-fuzz/usr/pkg/INVENTORY", *CIG_VAR = "/nonexistent-cig-fuzz/var",
           *CIG_REPO = "/nonexistent-cig-fuzz/repo", *CIGBUILD = "/nonexistent-cig-fuzz/cigbuild";

const char *fuzz_dict[] = { "\177ELF", "\x02\x01\x01", "libc.so", "$ORIGIN", ":", NULL };
size_t fuzz_max_len = 65536;

void fuzz_one(const uint8_t *data, size_t len)
{
	struct strv need = { 0 }, rp = { 0 };
	elf_needed(fuzz_file(data, len), &need, &rp);
	sv_free(&need);
	sv_free(&rp);
}

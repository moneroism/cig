/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* t_license.c - the libre-meter's SPDX expression parser (libre_license in src/libre) and
 * its package/firmware bookkeeping; license= comes from recipes and .PKGINFO */
#include "../../src/libre/libre.c"
#include "fuzz.h"

const char *fuzz_dict[] = { "GPL-2.0-only", "GPL-3.0-or-later", "MIT", "LicenseRef-x", "+",
	" AND ", " OR ", " WITH ", "(", ")", "Classpath-exception-2.0", NULL };
size_t fuzz_max_len = 4096;
static struct libre lib;

void fuzz_init(void)
{
	const char *repo = getenv("FUZZ_REPO");
	if (!libre_init(&lib, repo ? repo : ".", NULL))
		abort();
}

void fuzz_one(const uint8_t *data, size_t len)
{
	char *expr = malloc(len + 1);
	memcpy(expr, data, len);
	expr[len] = '\0';
	(void)libre_license(&lib, expr);
	free(expr);
}

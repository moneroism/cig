/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* libre-meter tests: license expressions and a small report (make test) */
#include "libre.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;

static void expect(const struct libre *l, const char *expr, enum libre_class want)
{
	enum libre_class got = libre_license(l, expr);
	if (got != want) {
		static const char *names[] = { "free", "non-free", "not reviewed" };
		printf("FAIL: %s -> %s, expected %s\n", expr, names[got], names[want]);
		fails++;
	}
}

int main(int argc, char **argv)
{
	struct libre l;
	if (argc != 3 || !libre_init(&l, argv[1], argv[2]))
		return 2;
	expect(&l, "MIT", LIBRE_FREE);
	expect(&l, "GPL-2.0-only", LIBRE_FREE);
	expect(&l, "GPL-2.0+", LIBRE_FREE);                       /* deprecated: -or-later */
	expect(&l, "curl", LIBRE_FREE);                           /* licenses-cig */
	expect(&l, "Artistic-1.0-Perl", LIBRE_UNREVIEWED);
	expect(&l, "Artistic-1.0-Perl OR GPL-1.0-or-later", LIBRE_FREE);
	expect(&l, "MIT AND Artistic-1.0-Perl", LIBRE_UNREVIEWED);
	expect(&l, "GPL-3.0-or-later WITH GCC-exception-3.1", LIBRE_FREE);
	expect(&l, "(MIT OR Artistic-1.0-Perl) AND (BSD-3-Clause)", LIBRE_FREE);
	expect(&l, "LicenseRef-foo", LIBRE_UNREVIEWED);
	expect(&l, "", LIBRE_UNREVIEWED);

	/* a system: two packages, free and non-free firmware, one with a free replacement */
	libre_add_package(&l, "musl", "MIT");
	libre_add_package(&l, "linux-firmware", "LicenseRef-linux-firmware");   /* skipped */
	libre_add_firmware(&l, "htc_9271.fw");
	libre_add_firmware(&l, "ath9k_htc/htc_9271-1.4.0.fw");
	libre_add_firmware(&l, "amdgpu/polaris10_mc.bin");
	libre_add_firmware(&l, "no/such/file.bin");
	libre_add_kernel(&l, "linux", "GPL-2.0-only");
	int ov, po, vs, nf, nn, nu;
	libre_scores(&l, &ov, &po, &vs, &nf, &nn, &nu);
	if (l.n != 6 || nf != 2 || nn != 4 || nu != 0 || ov != 33 || po != 50 || vs != 66) {
		printf("FAIL: scores n=%d free=%d non-free=%d unreviewed=%d overall=%d possible=%d vs=%d\n",
		       l.n, nf, nn, nu, ov, po, vs);
		fails++;
	}
	char *r = libre_report(&l);
	if (!strstr(r, "use ath9k_htc/htc_9271-1.4.0.fw instead of htc_9271.fw")) {
		printf("FAIL: no suggestion in the report\n");
		fails++;
	}
	if (getenv("LIBRE_SHOW"))
		fputs(r, stdout);
	free(r);
	libre_free(&l);
	printf(fails ? "%d test(s) failed\n" : "libre: all tests passed\n", fails);
	return fails != 0;
}

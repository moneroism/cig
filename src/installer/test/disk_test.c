/* SPDX-License-Identifier: GPL-3.0-or-later */
/* disk_test.c - run scenarios.txt through the C layout code (compare with disk_test.sh) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../disk.h"

#define TOTAL 209715200ULL   /* 100 GiB in 512-byte sectors */

static const char *fs_of(const char *dev)
{
	switch (dev[strlen(dev) - 1]) {
	case '1': return "vfat";
	case '2': return "ntfs";
	default:  return "ext4";
	}
}

static char *slurp(const char *p)
{
	FILE *f = fopen(p, "rb");
	static char buf[65536];
	size_t n = f ? fread(buf, 1, sizeof(buf) - 1, f) : 0;
	if (f)
		fclose(f);
	buf[n] = '\0';
	return buf;
}

static enum kind kind_of(const char *k)
{
	return !strcmp(k, "esp") ? K_ESP : !strcmp(k, "swap") ? K_SWAP : K_LINUX;
}

int main(void)
{
	static struct layout l;
	char line[512], *dump = slurp("fixture.dump");
	FILE *sc = fopen("scenarios.txt", "r");
	while (sc && fgets(line, sizeof(line), sc)) {
		if (line[0] == '#' || line[0] == '\n')
			continue;
		line[strcspn(line, "\n")] = '\0';
		char *bar = strchr(line, '|'), *save = NULL;
		*bar = '\0';
		char *name = strtok(line, " ");
		printf("== %s\n", name);
		layout_clear(&l, "sda", 512, TOTAL);
		for (char *c = strtok_r(bar + 1, ";", &save); c; c = strtok_r(NULL, ";", &save)) {
			char a[16] = "", b[16] = "", d[16] = "", e[16] = "";
			sscanf(c, "%15s %15s %15s %15s", a, b, d, e);
			if (!strcmp(a, "auto"))
				layout_auto(&l, !strcmp(b, "yes"), (unsigned)atoi(d), (unsigned)atoi(e));
			else if (!strcmp(a, "load"))
				layout_load(&l, "sda", 512, TOTAL, dump, fs_of);
			else if (!strcmp(a, "wipe"))
				layout_clear(&l, "sda", 512, TOTAL);
			else if (!strcmp(a, "mount"))
				layout_set_mount(&l, atoi(b) - 1, strcmp(d, "-") ? d : "");
			else if (!strcmp(a, "format"))
				l.p[atoi(b) - 1].format = !strcmp(d, "yes");
			else if (!strcmp(a, "del"))
				layout_del(&l, atoi(b) - 1);
			else if (!strcmp(a, "new")) {
				uint64_t s;
				if (!parse_size(d, 512, &s))
					return 1;
				int i = layout_new(&l, kind_of(b), s, "");
				layout_set_mount(&l, i, strcmp(e, "-") ? e : "");
			}
		}
		char *err = layout_check(&l);
		puts("problems:");
		for (char *p = strtok(err, "\n"); p; p = strtok(NULL, "\n"))
			printf("P %s\n", p);
		if (!*err) {   /* installable: the table sfdisk would get */
			char *t = table_script(&l);
			printf("table:\n%s", t);
			free(t);
		}
		free(err);
	}
	return 0;
}

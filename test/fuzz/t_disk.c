/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* t_disk.c - the installer's partition logic (src/installer/disk.c) on a fuzzed `sfdisk -d`
 * dump: names and fields of existing partitions are whatever another system wrote. Input:
 * <dump> "\n%%\n" <size words> "\n%%\n" <edit operations, 4 bytes each> */
#include <stdlib.h>
#include <string.h>

#include "../../src/installer/disk.h"
#include "fuzz.h"

const char *fuzz_dict[] = { "\n%%\n", "label: gpt\n", "label: dos\n", "label-id: ", "device: /dev/sda\n",
	"unit: sectors\n", "first-lba: 2048\n", "last-lba: ", "sector-size: 512\n", "/dev/sda1 : ",
	"start=", "size=", "type=", "uuid=", "name=\"", "attrs=", ", ", "\"", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
	"0FC63DAF-8483-4772-8E79-3D69D8477DE4", "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F", "cig-root", "cig-home",
	"rest", "512M", "1G", "40G", "2T", "0", "\n", NULL };
size_t fuzz_max_len = 16384;

static const char *fs_of(const char *dev)
{
	size_t n = strlen(dev);
	switch (n ? dev[n - 1] : 0) {
	case '1': return "vfat";
	case '2': return "ntfs";
	case '3': return "";
	default:  return "ext4";
	}
}

void fuzz_one(const uint8_t *data, size_t len)
{
	static struct layout l;
	static const char *const mounts[] = { "", "/", "/home", "/boot", "swap", "/x" };
	char *in = malloc(len + 1), *words, *ops, *save = NULL;
	memcpy(in, data, len);
	in[len] = '\0';
	words = strstr(in, "\n%%\n");
	if (words) {
		*words = '\0';
		words += 4;
	}
	ops = words ? strstr(words, "\n%%\n") : NULL;
	if (ops) {
		*ops = '\0';
		ops += 4;
	}
	uint64_t sect = len && (data[0] & 1) ? 4096 : 512, total = 209715200ULL * 512 / sect;
	layout_clear(&l, "sda", sect, total);
	layout_load(&l, "sda", sect, total, in, fs_of);
	char *w = words ? strtok_r(words, " ", &save) : NULL;
	size_t nops = ops ? (len - (size_t)(ops - in)) / 4 : 0;
	for (size_t i = 0; i < nops && i < 64; i++) {
		const uint8_t *o = (const uint8_t *)ops + 4 * i;
		int idx = l.n ? o[1] % (l.n + 1) : 0;   /* sometimes one past the end, as a UI bug would */
		if (idx >= l.n)
			idx = l.n ? l.n - 1 : 0;
		switch (o[0] % 7) {
		case 0:
			layout_auto(&l, o[1] & 1, o[2], o[3] % 64);
			break;
		case 1: {
			uint64_t s;
			if (w && parse_size(w, sect, &s)) {
				int k = layout_new(&l, (enum kind)(o[1] % 4), s, "");
				if (k >= 0)
					layout_set_mount(&l, k, mounts[o[2] % 6]);
			}
			w = strtok_r(NULL, " ", &save);
			break;
		}
		case 2:
			if (l.n)
				layout_del(&l, idx);
			break;
		case 3:
			if (l.n)
				layout_set_mount(&l, idx, mounts[o[2] % 6]);
			break;
		case 4:
			if (l.n)
				l.p[idx].format = o[2] & 1;
			break;
		case 5:
			layout_clear(&l, "sda", sect, total);
			break;
		case 6:
			(void)layout_place(&l);
			break;
		}
	}
	char *err = layout_check(&l);
	if (err && !*err) {
		char *t = table_script(&l);
		free(t);
	}
	for (int i = 0; i < l.n; i++) {
		char dev[96];
		(void)part_name(&l, i);
		(void)eff_fs(&l.p[i]);
		part_dev(l.disk, l.p[i].num, dev, sizeof(dev));
	}
	free(err);
	layout_clear(&l, "sda", sect, total);   /* frees the kept lines */
	free(in);
}

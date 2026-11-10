/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* wifi_test.c - wifi_parse() on `wpa_cli scan_results` output */
#include <stdio.h>
#include <string.h>

#include "../sys.h"
#include "../wifi.h"

/* wifi_scan() is not tested here: its commands only exist on a real machine */
bool file_exists(const char *p) { return false; }
int run(char *const argv[]) { return 1; }
char *capture(char *const argv[]) { return NULL; }

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

int main(void)
{
	struct wifi_net n[WIFI_MAX];
	const char *res =
		"bssid / frequency / signal level / flags / ssid\n"
		"aa:aa:aa:aa:aa:01\t2412\t-70\t[WPA2-PSK-CCMP][ESS]\tHome\n"
		"aa:aa:aa:aa:aa:02\t5180\t-48\t[WPA2-PSK-CCMP][ESS]\tHome\n"         /* same name, stronger */
		"aa:aa:aa:aa:aa:03\t2437\t-60\t[RSN-SAE-CCMP][ESS]\tWpa3Only\n"
		"aa:aa:aa:aa:aa:04\t2462\t-55\t[WPA2-PSK+SAE-CCMP][ESS]\tMixed\n"
		"aa:aa:aa:aa:aa:05\t2412\t-40\t[ESS]\tOpenCafe\n"                    /* open: not offered */
		"aa:aa:aa:aa:aa:06\t2412\t-41\t[WPA2-EAP-CCMP][ESS]\tOffice\n"       /* enterprise: not offered */
		"aa:aa:aa:aa:aa:07\t2412\t-42\t[WPA2-PSK-CCMP][ESS]\t\n"             /* hidden */
		"aa:aa:aa:aa:aa:08\t2412\t-80\t[WPA2-PSK-CCMP][ESS]\t\\xd0\\x94om \\\"q\\\" \\\\\n"
		"aa:aa:aa:aa:aa:09\t2412\t-81\t[WPA2-PSK-CCMP][ESS]\tbad\\nname\n"   /* control character */
		"aa:aa:aa:aa:aa:0a\t2412\t-82\t[WPA2-PSK-CCMP][ESS]\tnul\\x00\n"
		"aa:aa:aa:aa:aa:0b\t2412\t-83\t[WPA2-PSK-CCMP][ESS]\tcut\\x4\n"      /* malformed */
		"aa:aa:aa:aa:aa:0c\t2412\t-84\t[WPA2-PSK-CCMP][ESS]\t0123456789abcdef0123456789abcdefX\n"   /* 33 bytes */
		"aa:aa:aa:aa:aa:0d\t2412\t-85\t[WPA2-PSK-CCMP][ESS]\t0123456789abcdef0123456789abcdef\n"    /* 32 */
		"short line\n"
		"aa:aa:aa:aa:aa:0e\t2412\t-86\t[WPA2-PSK-CCMP][ESS]\tLast";             /* no newline at the end */
	int c = wifi_parse(res, n, WIFI_MAX);
	CHECK(c == 6);
	if (c == 6) {
		CHECK(!strcmp(n[0].ssid, "Home") && n[0].signal == -48 && n[0].wpa2 && !n[0].wpa3);
		CHECK(!strcmp(n[1].ssid, "Mixed") && n[1].wpa2 && n[1].wpa3);
		CHECK(!strcmp(n[2].ssid, "Wpa3Only") && !n[2].wpa2 && n[2].wpa3);
		CHECK(!strcmp(n[3].ssid, "\xd0\x94om \"q\" \\") && !strcmp(n[3].shown, "\\xd0\\x94om \\\"q\\\" \\\\"));
		CHECK(!strcmp(n[4].ssid, "0123456789abcdef0123456789abcdef"));
		CHECK(!strcmp(n[5].ssid, "Last"));
	}
	CHECK(wifi_parse(res, n, 2) == 2 && !strcmp(n[0].ssid, "Home"));
	CHECK(wifi_parse("", n, WIFI_MAX) == 0);
	CHECK(wifi_parse("header only\n", n, WIFI_MAX) == 0);
	CHECK(wifi_parse(NULL, n, WIFI_MAX) == 0);
	if (!fails)
		printf("wifi: all checks pass\n");
	return fails != 0;
}

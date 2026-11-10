/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* wifi.c - the WiFi networks in range, through wpa_cli. Network names never reach the
 * install log: scan results are captured, and no command line contains one. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "sys.h"
#include "wifi.h"

#define TEMP_CTRL "/run/cig-install-wpa"
#define TEMP_CONF "/tmp/cig-install-wpa.conf"

static int hexval(char c)
{
	return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10
	     : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
}

/* undo wpa_cli's printf_encode(): \\ \" \e \n \r \t \xNN; false if the name is too long,
 * malformed or has control characters (they can't go into wpa_supplicant.conf) */
static bool decode(const char *s, size_t len, char *out, size_t n)
{
	size_t o = 0;
	for (size_t i = 0; i < len; i++) {
		int c = (unsigned char)s[i];
		if (c == '\\') {
			if (++i >= len)
				return false;
			switch (s[i]) {
			case '\\': c = '\\'; break;
			case '"':  c = '"'; break;
			case 'x':
				if (i + 2 >= len || hexval(s[i + 1]) < 0 || hexval(s[i + 2]) < 0)
					return false;
				c = hexval(s[i + 1]) * 16 + hexval(s[i + 2]);
				i += 2;
				break;
			default: return false;   /* \e \n \r \t: control characters */
			}
		}
		if (c < 32 || c == 127 || o + 1 >= n)
			return false;
		out[o++] = (char)c;
	}
	out[o] = '\0';
	return o > 0;
}

static int by_signal(const void *a, const void *b)
{
	const struct wifi_net *x = a, *y = b;
	return x->signal != y->signal ? y->signal - x->signal : strcmp(x->shown, y->shown);
}

/* lines: bssid TAB frequency TAB signal TAB flags TAB ssid (the first line is a header) */
int wifi_parse(const char *results, struct wifi_net *nets, int max)
{
	int n = 0;
	const char *l = results ? strchr(results, '\n') : NULL;
	for (; l && *l; l = strchr(l, '\n')) {
		const char *f[5];
		const char *e = ++l;
		int k = 0;
		f[k++] = l;
		while (*e && *e != '\n') {
			if (*e == '\t' && k < 5)
				f[k++] = e + 1;
			e++;
		}
		if (k < 5)
			continue;
		size_t flen = (size_t)(f[4] - f[3] - 1), slen = (size_t)(e - f[4]);
		char flags[256], ssid[33];
		if (flen >= sizeof(flags) || slen >= sizeof(nets->shown) || !decode(f[4], slen, ssid, sizeof(ssid)))
			continue;   /* hidden (no name), or a name the config can't hold */
		memcpy(flags, f[3], flen);
		flags[flen] = '\0';
		/* Personal only: [WPA2-PSK-CCMP], [RSN-PSK+SAE-CCMP], [RSN-SAE-CCMP]; not EAP or open */
		bool wpa2 = strstr(flags, "-PSK") || strstr(flags, "+PSK"), wpa3 = strstr(flags, "SAE");
		if (!wpa2 && !wpa3)
			continue;
		int sig = atoi(f[2]), i;
		for (i = 0; i < n && strcmp(nets[i].ssid, ssid); i++)
			;
		if (i == n) {
			if (n == max)
				continue;
			n++;
			snprintf(nets[i].ssid, sizeof(nets[i].ssid), "%s", ssid);
			memcpy(nets[i].shown, f[4], slen);
			nets[i].shown[slen] = '\0';
			nets[i].signal = sig;
			nets[i].wpa2 = nets[i].wpa3 = false;
		} else if (sig > nets[i].signal) {
			nets[i].signal = sig;
		}
		nets[i].wpa2 |= wpa2;
		nets[i].wpa3 |= wpa3;
	}
	qsort(nets, (size_t)n, sizeof(*nets), by_signal);
	return n;
}

int wifi_scan(const char *ifname, struct wifi_net *nets, int max)
{
	char sock[64];
	const char *dir = "/run/wpa_supplicant";
	snprintf(sock, sizeof(sock), "%s/%s", dir, ifname);
	bool temp = !file_exists(sock);
	if (temp) {   /* no wpa_supplicant on this interface: one just for the scan */
		char *rf[] = { "rfkill", "unblock", "wifi", NULL };
		char *up[] = { "ip", "link", "set", (char *)ifname, "up", NULL };
		char *st[] = { "wpa_supplicant", "-B", "-i", (char *)ifname, "-c", TEMP_CONF, NULL };
		FILE *f = fopen(TEMP_CONF, "w");
		if (!f)
			return -1;
		fputs("ctrl_interface=" TEMP_CTRL "\npreassoc_mac_addr=1\n", f);   /* a random MAC while scanning */
		if (fclose(f) != 0)
			return -1;
		run(rf);   /* optional: not every system has rfkill or a block */
		run(up);
		if (run(st) != 0) {
			unlink(TEMP_CONF);
			return -1;
		}
		dir = TEMP_CTRL;
	}
	char *scan[] = { "wpa_cli", "-p", (char *)dir, "-i", (char *)ifname, "scan", NULL };
	char *res[] = { "wpa_cli", "-p", (char *)dir, "-i", (char *)ifname, "scan_results", NULL };
	bool started = false;
	for (int i = 0; i < 3 && !started; i++) {   /* FAIL-BUSY: a scan is already running */
		char *o = capture(scan);
		started = o && (!strcmp(o, "OK") || !strcmp(o, "FAIL-BUSY"));
		free(o);
		if (!started)
			sleep(1);
	}
	int n = started ? 0 : -1;
	/* results arrive within a few seconds: stop once they stay the same, at most 10 s */
	for (int t = 0, last = -1; started && t < 10; t++) {
		sleep(1);
		char *r = capture(res);
		n = r ? wifi_parse(r, nets, max) : 0;
		free(r);
		if (t >= 3 && n > 0 && n == last)
			break;
		last = n;
	}
	if (temp) {
		char *term[] = { "wpa_cli", "-p", TEMP_CTRL, "-i", (char *)ifname, "terminate", NULL };
		run(term);
		unlink(TEMP_CONF);
	}
	return n;
}

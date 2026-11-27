/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* wifi.h - the WiFi networks in range (wpa_cli scan), for the Network: WiFi screen */
#ifndef WIFI_H
#define WIFI_H

#include <stdbool.h>

#define WIFI_MAX 64

struct wifi_net {
	char ssid[33];    /* the name as bytes (no control characters) */
	char shown[136];  /* the name as wpa_cli prints it: printable ASCII, \xNN for the rest */
	int signal;       /* dBm, the strongest access point with this name */
	bool wpa2, wpa3;  /* WPA2-Personal (PSK), WPA3-Personal (SAE) */
};

/* `wpa_cli scan_results` output -> the WPA2/WPA3-Personal networks with a name, one per
 * name, strongest first; returns how many (at most max) */
int wifi_parse(const char *results, struct wifi_net *nets, int max);

/* scan on ifname (through the running wpa_supplicant, or a temporary one); -1 if no scan
 * could be started, else as wifi_parse */
int wifi_scan(const char *ifname, struct wifi_net *nets, int max);

#endif

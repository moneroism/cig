/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* libreui.h - the libre-meter in the installer */
#ifndef LIBREUI_H
#define LIBREUI_H

#include "state.h"

/* the main menu's value: the scores for the current choices */
char *libre_value(const struct state *s);
/* the report, and the choice of free firmware replacements (s->free_fw) */
void libre_screen(struct state *s);
/* the firmware list ("\n"-separated) with the free replacements used (s->free_fw); NULL
 * without license data */
char *libre_install_firmware(const struct state *s);

#endif

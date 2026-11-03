/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* libreui.h - the libre-meter in the installer */
#ifndef LIBREUI_H
#define LIBREUI_H

#include "state.h"

/* the main menu's value: the scores for the current choices */
char *libre_value(const struct state *s);
/* the report */
void libre_screen(struct state *s);

#endif

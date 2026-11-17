# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# clock - the time in large digits for the terminal (C, libc only).
CC ?= cc
CFLAGS ?= -O2 -pipe
CFLAGS += -std=c17 -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wstrict-prototypes -Wvla \
          -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE
LDFLAGS ?= -Wl,-z,relro,-z,now
LDFLAGS += -pie

clock: clock.c
	$(CC) $(CFLAGS) -o $@ clock.c $(LDFLAGS)

clean:
	rm -f clock

.PHONY: clean

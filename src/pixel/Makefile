# SPDX-License-Identifier: GPL-3.0-or-later
# pixel - terminal animations. Strict warnings, hardened by default.
CC      ?= cc
CFLAGS  ?= -O2 -pipe
CFLAGS  += -std=c17 -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wstrict-prototypes -Wvla \
           -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE
LDFLAGS ?= -Wl,-z,relro,-z,now
LDFLAGS += -pie

pixel: pixel.c
	$(CC) $(CFLAGS) -o $@ pixel.c $(LDFLAGS)

clean:
	rm -f pixel

.PHONY: clean

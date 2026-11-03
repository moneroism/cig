# SPDX-License-Identifier: GPL-3.0-or-later
# libre-meter (shared by smoke and the installer): only its tests are built here.
CC      ?= cc
CFLAGS  ?= -O2 -pipe
CFLAGS  += -std=c17 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
           -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wstrict-prototypes \
           -Wmissing-prototypes -Wvla -Wno-unused-parameter

libre-test: test.c libre.c libre.h
	$(CC) $(CFLAGS) -o $@ test.c libre.c

# the repository's own data (libre/) and a small firmware index
test: libre-test
	./libre-test ../.. test/firmware.licenses

clean:
	rm -f libre-test

.PHONY: test clean

# SPDX-License-Identifier: GPL-3.0-or-later
# smoke - cig's package manager (C). Strict warnings, hardened by default.
CC      ?= cc
CFLAGS  ?= -O2 -pipe
CFLAGS  += -std=c17 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
           -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wstrict-prototypes \
           -Wmissing-prototypes -Wvla -Wno-unused-parameter \
           -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE
LDFLAGS ?= -Wl,-z,relro,-z,now
LDFLAGS += -pie
OBJ     = main.o util.o sha256.o inventory.o install.o remove.o audit.o

smoke: $(OBJ)
	$(CC) $(CFLAGS) -o $@ $(OBJ) $(LDFLAGS)

$(OBJ): smoke.h

# debug build: AddressSanitizer + UndefinedBehaviorSanitizer
asan:
	$(MAKE) clean
	$(MAKE) CFLAGS="-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer" \
	        LDFLAGS="-fsanitize=address,undefined"

clean:
	rm -f smoke $(OBJ)

.PHONY: asan clean

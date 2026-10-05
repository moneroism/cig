# SPDX-License-Identifier: GPL-3.0-or-later
# cig-install - the installer (C, ncurses). Strict warnings, hardened by default.
CC      ?= cc
CFLAGS  ?= -O2 -pipe
CFLAGS  += -std=c17 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
           -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wstrict-prototypes \
           -Wvla -Wno-unused-parameter \
           -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE
LDFLAGS ?= -Wl,-z,relro,-z,now
LDFLAGS += -pie
LIBS    = -lncursesw
OBJ     = main.o ui.o diskui.o disk.o install.o sys.o

cig-install: $(OBJ)
	$(CC) $(CFLAGS) -o $@ $(OBJ) $(LDFLAGS) $(LIBS)

$(OBJ): disk.h state.h sys.h ui.h

test: disk.o
	./test/run.sh

clean:
	rm -f cig-install $(OBJ)

.PHONY: test clean

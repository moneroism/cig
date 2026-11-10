/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* fuzz.h - what a fuzz target provides to the driver (fuzz.c) */
#ifndef CIG_FUZZ_H
#define CIG_FUZZ_H

#include <stddef.h>
#include <stdint.h>

/* run the code under test on one input; must not keep state between calls (or reset it) */
void fuzz_one(const uint8_t *data, size_t len);

/* optional (weak): once per child process, before the first input */
void fuzz_init(void);

/* optional (weak): words the mutator inserts (NULL-terminated), and the largest input */
extern const char *fuzz_dict[];
extern size_t fuzz_max_len;

/* the input as a file, for code that only reads paths (fd stays open; rewritten per input) */
const char *fuzz_file(const uint8_t *data, size_t len);

#endif

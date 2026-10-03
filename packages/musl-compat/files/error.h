/* SPDX-License-Identifier: GPL-3.0-or-later
 * error.h - glibc-style error() / error_at_line() for musl (header only). */
#ifndef _CIG_ERROR_H
#define _CIG_ERROR_H

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char *program_invocation_name;

static unsigned int error_message_count = 0;
static int error_one_per_line = 0;

static inline void error(int status, int errnum, const char *fmt, ...)
{
	va_list ap;
	fflush(stdout);
	fprintf(stderr, "%s: ", program_invocation_name);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	if (errnum)
		fprintf(stderr, ": %s", strerror(errnum));
	fputc('\n', stderr);
	error_message_count++;
	if (status)
		exit(status);
}

static inline void error_at_line(int status, int errnum, const char *file,
                                 unsigned int line, const char *fmt, ...)
{
	va_list ap;
	(void)error_one_per_line;
	fflush(stdout);
	fprintf(stderr, "%s:%s:%u: ", program_invocation_name, file, line);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	if (errnum)
		fprintf(stderr, ": %s", strerror(errnum));
	fputc('\n', stderr);
	error_message_count++;
	if (status)
		exit(status);
}

#endif

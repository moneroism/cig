/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 moneroism */
/* glibc's <sys/cdefs.h>, which musl does not have, reduced to what Chromium's sources take
 * from it (Alpine builds with bsd-compat-headers for the same reason). Build-time only. */
#ifndef CIG_COMPAT_SYS_CDEFS_H
#define CIG_COMPAT_SYS_CDEFS_H
#ifdef __cplusplus
#define __BEGIN_DECLS extern "C" {
#define __END_DECLS }
#else
#define __BEGIN_DECLS
#define __END_DECLS
#endif
#if defined(__GNUC__) && !defined(__cplusplus)
#define __THROW __attribute__((__nothrow__))
#else
#define __THROW
#endif
#define __P(args) args
#define __CONCAT(x, y) x ## y
#define __STRING(x) #x
#endif

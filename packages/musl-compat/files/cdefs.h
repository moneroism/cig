/* SPDX-License-Identifier: GPL-3.0-or-later
 * sys/cdefs.h - minimal BSD/glibc compatibility macros for musl. */
#ifndef _CIG_SYS_CDEFS_H
#define _CIG_SYS_CDEFS_H

#ifdef __cplusplus
# define __BEGIN_DECLS extern "C" {
# define __END_DECLS   }
#else
# define __BEGIN_DECLS
# define __END_DECLS
#endif

#define __P(args)     args
#define __PMT(args)   args
#define __CONCAT(x,y) x ## y
#define __STRING(x)   #x
#ifndef __THROW
# define __THROW
#endif
#ifndef __NTH
# define __NTH(fct) fct
#endif
#ifndef __attribute_pure__
# define __attribute_pure__ __attribute__((__pure__))
#endif

#endif

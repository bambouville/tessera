/*
 * config.h for building mosh on iOS as an SPM cxxTarget.
 *
 * Mosh upstream uses GNU autotools to generate config.h per platform.
 * iOS builds can't run `configure`, so this file is hand-authored from
 * the probes that matter for iOS 17+ / Darwin / arm64 / libc++.
 *
 * Conventions per the integration plan:
 *   - Define what's actually available on Darwin.
 *   - LEAVE UNDEFINED anything Linux-specific. Defining
 *     HAVE_IP_MTU_DISCOVER / HAVE_IP_RECVTOS makes
 *     Network::Connection::set_MTU_options issue sendto with EINVAL.
 *     Leaving HAVE_SECURE_GETENV undefined makes mosh fall back to
 *     plain getenv (Darwin doesn't have secure_getenv).
 *
 * Crypto backend: USE_APPLE_COMMON_CRYPTO_AES = 1 so ocb_internal.cc
 * uses Apple CommonCrypto for the AES block cipher. No OpenSSL dep
 * on iOS.
 *
 * Package version strings are only used in mosh-client.cc (frontend
 * we're replacing) and a few log messages. Minimal values keep link
 * alive.
 */

#ifndef MOSH_IOS_CONFIG_H
#define MOSH_IOS_CONFIG_H

/* ---- package metadata (minimal; frontend is replaced by our client) ---- */
#define PACKAGE_STRING          "mosh (tessera-ios)"
#define PACKAGE_NAME            "mosh"
#define PACKAGE                 "mosh"
#define VERSION                 "1.4.0-tessera"
#define PACKAGE_VERSION         "1.4.0-tessera"
#define PACKAGE_BUGREPORT       "https://github.com/mobile-shell/mosh/issues"
#define PACKAGE_TARNAME         "mosh"
#define PACKAGE_URL             "https://mosh.org"

/* ---- crypto backend ---- */
#define USE_APPLE_COMMON_CRYPTO_AES     1

/* ---- POSIX header probes ---- */
#define HAVE_SYS_SOCKET_H               1
#define HAVE_SYS_UIO_H                  1
#define HAVE_SYS_TYPES_H                1
#define HAVE_NETINET_IN_H               1
#define HAVE_ARPA_INET_H                1
#define HAVE_INTTYPES_H                 1
#define HAVE_STDINT_H                   1
#define HAVE_STDLIB_H                   1
#define HAVE_STRING_H                   1
#define HAVE_STRINGS_H                  1
#define HAVE_UNISTD_H                   1
#define HAVE_LANGINFO_H                 1
#define HAVE_LOCALE_H                   1
#define HAVE_WCHAR_H                    1
#define HAVE_WCTYPE_H                   1
#define HAVE_PWD_H                      1

/* ---- function probes ---- */
#define HAVE_CLOCK_GETTIME              1
#define HAVE_GETTIMEOFDAY               1
#define HAVE_INET_PTON                  1
#define HAVE_INET_NTOP                  1
#define HAVE_MACH_ABSOLUTE_TIME         1
#define HAVE_GETADDRINFO                1
#define HAVE_GETNAMEINFO                1

/* ---- C++ library probes ---- */
#define HAVE_MEMORY                     1
#define HAVE_STD_SHARED_PTR             1

/* ---- socket flags ---- */
#define HAVE_MSG_DONTWAIT               1

/* ---- Linux-only things — DO NOT DEFINE ---- */
/* #undef HAVE_IP_MTU_DISCOVER      — Linux-specific sockopt, EINVAL on Darwin */
/* #undef HAVE_IP_RECVTOS           — same */
/* #undef HAVE_SECURE_GETENV        — Darwin doesn't have it; mosh falls back to getenv */
/* #undef HAVE_ENDIAN_H             — Linux glibc header; use byteorder.h instead */
/* #undef HAVE_SYS_ENDIAN_H         — BSD, not present on Darwin in the path mosh expects */
/* #undef HAVE_PSELECT              — we bypass mosh's Select loop entirely */

/* ---- mosh-client terminal concerns we skip client-side ---- */
/* SwiftTerm does the rendering, so we don't need terminfo or curses. */
/* #undef HAVE_NCURSES_H */
/* #undef HAVE_CURSES_H */

/* ---- OS type markers some mosh sources sniff ---- */
#define HAVE_TYPEOF_MACRO               0

/* ---- misc ---- */
#define STDC_HEADERS                    1

/* ---- clang builtins (use these instead of manual bit fiddling) ---- */
#define HAVE_DECL___BUILTIN_BSWAP64     1
#define HAVE_DECL___BUILTIN_CTZ         1

#endif /* MOSH_IOS_CONFIG_H */

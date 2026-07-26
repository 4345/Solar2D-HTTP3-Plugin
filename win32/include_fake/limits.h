// limits.h
// Минимальная заглушка для компиляции без Windows SDK.

#pragma once

#define CHAR_BIT      8
#define SCHAR_MIN   (-128)
#define SCHAR_MAX     127
#define UCHAR_MAX     0xff

#define SHRT_MIN    (-32768)
#define SHRT_MAX      32767
#define USHRT_MAX     0xffff

#define INT_MIN     (-2147483647 - 1)
#define INT_MAX       2147483647
#define UINT_MAX      0xffffffffU

#define LONG_MIN    (-2147483647L - 1L)
#define LONG_MAX      2147483647L
#define ULONG_MAX     0xffffffffUL

#define LLONG_MIN   (-9223372036854775807LL - 1LL)
#define LLONG_MAX     9223372036854775807LL
#define ULLONG_MAX    0xffffffffffffffffULL

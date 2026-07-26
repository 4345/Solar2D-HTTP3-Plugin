// stdio.h
// Минимальная заглушка для компиляции без Windows SDK.

#pragma once
#include <stddef.h>

#define BUFSIZ 1024

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FILE FILE;

#ifdef __cplusplus
}
#endif

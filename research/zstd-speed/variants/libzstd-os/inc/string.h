/* Freestanding shim for libzstd in wasm32: the Zig compiler_rt gives these. */
#pragma once
#include <stddef.h>
void *memcpy(void *d, const void *s, size_t n);
void *memmove(void *d, const void *s, size_t n);
void *memset(void *p, int v, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);

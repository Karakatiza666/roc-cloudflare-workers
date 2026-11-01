/* Freestanding shim: libzstd gets a custom allocator, so these are never called (zstd.zig traps). */
#pragma once
#include <stddef.h>
void *malloc(size_t n);
void *calloc(size_t n, size_t s);
void free(void *p);

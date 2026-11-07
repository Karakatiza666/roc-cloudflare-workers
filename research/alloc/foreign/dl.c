// dlmalloc (the wasi-libc default) as a backend of fa.zig. Config as wasi-libc dlmalloc/src/dlmalloc.c.
#include <stddef.h>
#define HAVE_MMAP 0
#define MORECORE_CANNOT_TRIM 1
#define ABORT __builtin_trap()
#define LACKS_TIME_H 1
#define NO_MALLINFO 1
#define NO_MALLOC_STATS 1
#define MALLOC_ALIGNMENT 16
#define MALLOC_FAILURE_ACTION
#define malloc_getpagesize ((size_t)65536U)
#define USE_DL_PREFIX 1
#define DLMALLOC_EXPORT static inline
static size_t dlmalloc_usable_size(void *);
#include "vendor/dlmalloc.c"
void *fa_malloc(size_t n) { return dlmalloc(n); }
void fa_free(void *p) { dlfree(p); }
void *fa_realloc(void *p, size_t n) { return dlrealloc(p, n); }
size_t fa_usable(void *p) { return dlmalloc_usable_size(p); }

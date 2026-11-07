// mimalloc 2.2.4 (wasi prim with MI_USE_SBRK: memory from the sbrk of fa.zig) as a backend of fa.zig. One unit: src/static.c.
// The libc calls that mimalloc makes get local stubs (renamed, so no global symbol clashes with Roc's builtins).
#define MI_DEBUG 0
#define MI_SECURE 0
#define MI_STAT 0
#define NDEBUG 1
#define MI_USE_SBRK 1
#define MI_DEFAULT_ARENA_RESERVE 4096L  // KiB: one 4 MiB segment (32-bit), not 128 MiB
#define strstr fa_mi_strstr
#define strtol fa_mi_strtol
#define getenv fa_mi_getenv
#define fputs fa_mi_fputs
#define sched_yield fa_mi_sched_yield
#define clock_gettime fa_mi_clock_gettime
#include <errno.h>
#include <stdio.h>
static int fa_mi_errno;
#undef errno
#define errno fa_mi_errno
#undef stderr
#define stderr ((FILE *)0)
#undef stdout
#define stdout ((FILE *)0)
#include "vendor/mimalloc-2.2.4/src/static.c"
// Weak: the compiler emits these names itself; a strong copy elsewhere wins.
__attribute__((weak)) size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
char *fa_mi_strstr(const char *h, const char *n) { (void)n; (void)h; return 0; }
long fa_mi_strtol(const char *s, char **e, int b) { (void)b; if (e) *e = (char *)s; return 0; }
char *fa_mi_getenv(const char *n) { (void)n; return 0; }
int fa_mi_fputs(const char *s, FILE *f) { (void)s; (void)f; return 0; }
int fa_mi_sched_yield(void) { return 0; }
int fa_mi_clock_gettime(clockid_t c, struct timespec *t) { (void)c; t->tv_sec = 0; t->tv_nsec = 0; return 0; }
__attribute__((weak)) int __cxa_atexit(void (*f)(void *), void *a, void *d) { (void)f; (void)a; (void)d; return 0; }
void *fa_malloc(size_t n) { return mi_malloc(n); }
void fa_free(void *p) { mi_free(p); }
void *fa_realloc(void *p, size_t n) { return mi_realloc(p, n); }
size_t fa_usable(void *p) { return mi_usable_size(p); }

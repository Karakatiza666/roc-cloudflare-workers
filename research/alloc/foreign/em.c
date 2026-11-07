// emmalloc (the emscripten default) as a backend of fa.zig. Stub emscripten headers: em_inc/.
#include <stddef.h>
#include <stdint.h>
#define EMMALLOC_NO_STD_EXPORTS 1
#define EM_ASM(...) ((void)0)
#define MAIN_THREAD_ASYNC_EM_ASM(...) ((void)0)
#define NDEBUG 1
#define EM_JS_DEPS(a, b)
struct mallinfo { size_t arena, ordblks, smblks, hblks, hblkhd, usmblks, fsmblks, uordblks, fordblks, keepcost; };
extern void *sbrk(intptr_t);
void *_sbrk64(int64_t n) { return sbrk((intptr_t)n); }
size_t emscripten_get_heap_size(void) { return __builtin_wasm_memory_size(0) * 65536; }
size_t emscripten_get_heap_max(void) { return 128u << 20; }
void emscripten_errf(const char *f, ...) { (void)f; }
void emmalloc_free(void *);
#define free emmalloc_free
#include "vendor/emmalloc_fa.c"  // fetch.sh: MALLOC_ALIGNMENT 8, as in emscripten
void *fa_malloc(size_t n) { return emmalloc_malloc(n); }
void fa_free(void *p) { emmalloc_free(p); }
void *fa_realloc(void *p, size_t n) { return emmalloc_realloc(p, n); }
size_t fa_usable(void *p) { return emmalloc_usable_size(p); }

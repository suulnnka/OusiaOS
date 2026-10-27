/* ZOS libc —— <assert.h> */
#undef assert
#ifdef NDEBUG
#define assert(x) ((void)0)
#else
void __zos_assert_fail(const char *expr, const char *file, int line) __attribute__((noreturn));
#define assert(x) ((x) ? (void)0 : __zos_assert_fail(#x, __FILE__, __LINE__))
#endif

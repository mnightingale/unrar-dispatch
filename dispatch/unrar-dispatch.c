/*
 * unrar ISA dispatcher.
 *
 * Detects the host's x86-64 microarchitecture level and execv()s the matching
 * unrar build. The vendored unrar source is not modified in any way; each
 * variant is a whole binary compiled at a different -march level, so every
 * translation unit is internally consistent (which matters here, because
 * ALLOW_MISALIGNED in os.hpp:270 changes PPM struct packing in model.hpp /
 * suballoc.hpp, and unpack.cpp aggregates ten decoder .cpp files into one
 * object).
 *
 * execv is used rather than dlopen so that exit codes, signal handling,
 * stdin/stdout/tty ownership and process-tree semantics are bit-identical to
 * running unrar directly. dlopen would additionally cost -fPIC GOT
 * indirection in exactly the loops this is meant to speed up.
 *
 * Build with plain -O2 and no -march: this binary must run on the baseline.
 */

/*
 * Feature-test macros must precede every #include.
 *
 * Under a strict -std=c99 glibc exposes neither readlink() (POSIX.1-2001),
 * strdup()/realpath(path,NULL) (POSIX.1-2008) nor PATH_MAX. Apple's headers
 * are lax by default, so omitting these builds fine on macOS and fails on
 * Linux. Declaring what we use keeps -std=c99 rather than falling back to
 * -std=gnu99.
 */
#if defined(__APPLE__)
#  ifndef _DARWIN_C_SOURCE
#    define _DARWIN_C_SOURCE 1
#  endif
#elif !defined(_POSIX_C_SOURCE)
#  define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <errno.h>

#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <stdint.h>     /* uint32_t, for _NSGetExecutablePath */
#endif

/*
 * PATH_MAX is allowed to be undefined on systems with no fixed path limit
 * (GNU/Hurd). We only need a sane buffer for the executable's own path.
 */
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* Where variants live when installed system-wide. Override at build time. */
#ifndef UNRAR_VARIANT_DIR
#define UNRAR_VARIANT_DIR "/usr/libexec/unrar"
#endif

/* Subdirectory searched next to the wrapper, for portable/tarball installs. */
#ifndef UNRAR_VARIANT_SUBDIR
#define UNRAR_VARIANT_SUBDIR "unrar-isa"
#endif

/* RARX_FATAL from errhnd.hpp:8 - used when no variant can be executed. */
#define EXIT_DISPATCH_FAILED 2

/* Highest level first: the fallback walk relies on this order. */
static const char *const kLevels[] = { "x86-64-v3", "x86-64-v2", "x86-64" };
#define NLEVELS ((int)(sizeof(kLevels) / sizeof(kLevels[0])))

/*
 * Index into kLevels of the best level this CPU supports.
 *
 * Explicit feature queries rather than __builtin_cpu_supports("x86-64-v3"),
 * which needs GCC 12+ / Clang 12+. GCC and Clang's cpu_indicator_init already
 * gates the AVX bits on OSXSAVE/xgetbv, so OS-level AVX state enablement is
 * covered. This also lands correctly on v2 under Rosetta 2, which provides
 * SSE4.2 but not AVX2.
 */
static int detect_level(void)
{
#if defined(__x86_64__) || defined(_M_X64)
    __builtin_cpu_init();

    /* x86-64-v3: AVX2, BMI1/2, F16C, FMA, LZCNT, MOVBE on top of v2. */
    if (__builtin_cpu_supports("avx2") &&
        __builtin_cpu_supports("bmi2") &&
        __builtin_cpu_supports("fma"))
        return 0;

    /* x86-64-v2: SSE3/SSSE3/SSE4.1/SSE4.2, POPCNT, CX16, LAHF-SAHF. */
    if (__builtin_cpu_supports("sse4.2") &&
        __builtin_cpu_supports("popcnt"))
        return 1;
#endif
    return NLEVELS - 1;
}

/* Absolute path of this executable, or NULL. Caller frees. */
static char *self_path(void)
{
    char buf[PATH_MAX];

#if defined(__APPLE__)
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0)
        return NULL;
    char *resolved = realpath(buf, NULL);
    return resolved ? resolved : strdup(buf);
#else
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0)
        return NULL;
    buf[n] = '\0';
    return strdup(buf);
#endif
}

/* Directory component of path, newly allocated. Caller frees. */
static char *dir_of(const char *path)
{
    const char *slash = strrchr(path, '/');
    if (!slash)
        return NULL;
    size_t len = (size_t)(slash - path);
    char *dir = malloc(len + 1);
    if (!dir)
        return NULL;
    memcpy(dir, path, len);
    dir[len] = '\0';
    return dir;
}

/* Build "<dir>/unrar.<level>" if it exists and is executable. Caller frees. */
static char *candidate(const char *dir, const char *level)
{
    if (!dir)
        return NULL;
    size_t need = strlen(dir) + strlen("/unrar.") + strlen(level) + 1;
    char *path = malloc(need);
    if (!path)
        return NULL;
    snprintf(path, need, "%s/unrar.%s", dir, level);
    if (access(path, X_OK) == 0)
        return path;
    free(path);
    return NULL;
}

/*
 * Search order for the variant directory:
 *   1. UNRAR_ISA_DIR         - explicit override
 *   2. <wrapper dir>/unrar-isa  - portable tarball, no install step
 *   3. <wrapper dir>            - variants sitting beside the wrapper
 *   4. UNRAR_VARIANT_DIR     - compile-time system location
 */
static char *find_variant(const char *level, char *selfdir)
{
    char *path;
    const char *env = getenv("UNRAR_ISA_DIR");

    if (env && *env && (path = candidate(env, level)))
        return path;

    if (selfdir) {
        size_t need = strlen(selfdir) + 1 + strlen(UNRAR_VARIANT_SUBDIR) + 1;
        char *sub = malloc(need);
        if (sub) {
            snprintf(sub, need, "%s/%s", selfdir, UNRAR_VARIANT_SUBDIR);
            path = candidate(sub, level);
            free(sub);
            if (path)
                return path;
        }
        if ((path = candidate(selfdir, level)))
            return path;
    }

    return candidate(UNRAR_VARIANT_DIR, level);
}

int main(int argc, char *argv[])
{
    /* argv is forwarded to execv wholesale and is already NULL-terminated,
       so the count is never needed. */
    (void)argc;

    int start = detect_level();

    /*
     * UNRAR_ISA pins a level. This is what makes post-install benchmarking
     * repeatable, and is the escape hatch for AVX2-downclocking workloads or
     * a VM reporting bad CPUID.
     */
    const char *pin = getenv("UNRAR_ISA");
    if (pin && *pin) {
        int found = 0;
        for (int i = 0; i < NLEVELS; i++) {
            if (strcmp(pin, kLevels[i]) == 0) {
                start = i;
                found = 1;
                break;
            }
        }
        if (!found) {
            fprintf(stderr, "unrar: unknown UNRAR_ISA value '%s' (expected one of:", pin);
            for (int i = 0; i < NLEVELS; i++)
                fprintf(stderr, " %s", kLevels[i]);
            fprintf(stderr, ")\n");
            return EXIT_DISPATCH_FAILED;
        }
    }

    char *self = self_path();
    char *selfdir = self ? dir_of(self) : NULL;

    /*
     * Walk down from the detected level. A missing higher variant is not an
     * error - it lets a packager ship a subset without changing the wrapper.
     */
    for (int i = start; i < NLEVELS; i++) {
        char *path = find_variant(kLevels[i], selfdir);
        if (!path)
            continue;

        /* argv is passed through untouched, argv[0] included. */
        execv(path, argv);

        /* Only reached if exec failed; try the next level down. */
        fprintf(stderr, "unrar: cannot execute %s: %s\n", path, strerror(errno));
        free(path);
    }

    fprintf(stderr,
            "unrar: no runnable unrar variant found.\n"
            "       Looked for unrar.<level> in $UNRAR_ISA_DIR, %s%s%s, and %s\n",
            selfdir ? selfdir : "", selfdir ? "/" UNRAR_VARIANT_SUBDIR ", " : "",
            selfdir ? selfdir : "(wrapper dir unknown)", UNRAR_VARIANT_DIR);

    free(selfdir);
    free(self);
    return EXIT_DISPATCH_FAILED;
}

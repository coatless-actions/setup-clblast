/*
 * CLBlast correctness verifier.
 *
 * Runs one 64x64 single-precision GEMM on the first OpenCL device the loader
 * offers, and compares it element-by-element against a double-precision
 * reference computed on the host. Prints key=value lines and exits with a
 * code the action can branch on without re-parsing text.
 *
 * The comparison is the entire point. Measured on macOS 26.5.1 arm64 with a
 * cold PoCL kernel cache and SDKROOT unset: PoCL's runtime kernel link fails
 * ("ld: library 'System' not found"), CLBlastSgemm still returns
 * CLBlastSuccess, and the output buffer is left holding garbage. There is no
 * status code to check. Any verifier that trusts CLBlastSuccess passes on a
 * configuration that computes nothing.
 *
 * Inputs are small integers exactly representable in binary32, and the
 * reference accumulates in double, so an exactly-correct device produces
 * max-abs-error=0. The 1e-3 threshold is therefore enormous headroom against
 * fp32 rounding (worst case here is ~1e-2 relative to values of order 16,
 * i.e. still exact) and catches only real breakage, never noise.
 *
 * A correct GEMM is only half of what the caller needs to know. "A correct
 * GEMM happened" and "a correct GEMM happened on the library this action
 * installed" are different claims, and until this file reported the second
 * one only the first was ever checked. Nothing in a compile-and-link cycle
 * pins down which CLBlast or which ICD loader ends up behind the call:
 * install-linux.sh's package branch emits a bare '-lclblast' with no -L at
 * all, so any libclblast on the default search path satisfies the link, and
 * Windows resolves clblast.dll and OpenCL.dll through the PE search order,
 * which consults the application directory and System32 *before* PATH -- so
 * the loader a caller put on PATH is the last candidate considered, not the
 * first. A system, vcpkg, or OS-shipped copy substituting itself would pass
 * every numeric check here while the library the action installed was never
 * loaded at all. The identity keys below close that gap by reporting what
 * the process is actually bound to; the caller compares them against the
 * paths it installed. This file measures and does not enforce -- only the
 * caller knows which paths were supposed to win.
 */

/* dladdr, Dl_info and RTLD_NEXT are all __USE_GNU on glibc, so this has to be
 * defined before any system header is pulled in. Already defined on some
 * toolchains (g++ defines it unconditionally); redefining it would be a
 * warning on every compile. */
#ifndef _GNU_SOURCE
#  define _GNU_SOURCE
#endif

#define CL_TARGET_OPENCL_VERSION 300
#define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#define CL_SILENCE_DEPRECATION

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <limits.h>

#if defined(_WIN32)
#  include <windows.h>
#else
#  include <dlfcn.h>
#endif

#include <CL/cl.h>
#include <clblast_c.h>

#define N 64
#define TOLERANCE 1e-3

/* Exit codes are part of the contract action.yml branches on: 0 only for
 * ok, 2 only when there was nothing to test on, 1 for every other status
 * (a real failure: setup broke, or the answer is wrong). */
#define EXIT_NOTHING_TO_TEST 2

/* CL_PLATFORM_NAME and CL_DEVICE_NAME are unbounded in the specification;
 * every runtime this action runs against is far inside this. A name that did
 * not fit would be reported empty rather than truncated, since a truncated
 * identity is a wrong answer rather than a shorter one. */
#define IDENTITY_MAX 256

/* Room for any absolute path on the platforms this compiles for; PATH_MAX is
 * 1024 on macOS and 4096 on Linux, and Windows paths reach 32767 only with
 * long-path opt-in, which no runner tree uses. */
#define MODULE_PATH_MAX 4096

#ifndef PATH_MAX
#  define PATH_MAX 4096
#endif

static float a[N * N];
static float b[N * N];
static float c[N * N];
static float ref[N * N];

/* Identity of what actually ran, filled in as each piece becomes known and
 * printed on every exit path -- including the bail paths, where an empty
 * platform or device name is the honest answer rather than a missing key.
 * The six keys of the contract appear on every run, always in the same
 * order, so a caller can parse without knowing which path was taken.
 *
 * The module paths start at "unknown" rather than empty: "the loaded module
 * could not be identified" and "nothing was loaded" are different facts, and
 * a caller comparing this against an expected path must not silently accept
 * the first as a match for the second. */
static char platform_name[IDENTITY_MAX] = "";
static char device_name[IDENTITY_MAX] = "";
static char clblast_module[MODULE_PATH_MAX] = "unknown";
static char opencl_module[MODULE_PATH_MAX] = "unknown";

/* Device and platform names may legitimately contain newlines; one would
 * split a key=value line in two and, downstream, corrupt $GITHUB_OUTPUT. */
static void flatten(char *s)
{
    for (; *s != '\0'; s++)
    {
        if (*s == '\n' || *s == '\r') { *s = ' '; }
    }
}

static void copy_into(char *dest, size_t dest_size, const char *src)
{
    size_t i = 0;
    for (; src[i] != '\0' && i + 1 < dest_size; i++) { dest[i] = src[i]; }
    dest[i] = '\0';
}

#if defined(_WIN32)

/* Looked up by module name rather than by symbol address, which is not a
 * shortcut but the only correct option on PE. The address of an imported
 * function, taken inside the importing module, is the thunk the linker
 * planted in this executable -- so asking which module owns that address
 * names the verifier itself, never the DLL behind it. GetModuleHandleA
 * matches on the base name the loader recorded, which is exactly the name in
 * the import table, and GetModuleFileNameA reports where that module was
 * actually found. Finding it somewhere other than the tree this action
 * installed is the whole reason the key exists.
 *
 * A NULL handle means the DLL is not loaded in this process at all, which
 * would itself be news; "unknown" is left in place for the caller to reject.
 */
static void resolve_module(const char *module_name, char *out, size_t out_size)
{
    char path[MODULE_PATH_MAX];
    HMODULE handle = GetModuleHandleA(module_name);
    DWORD written;

    if (handle == NULL) { return; }

    written = GetModuleFileNameA(handle, path, (DWORD) sizeof path);

    /* 0 is failure. A count equal to the buffer size means the path was
     * truncated, and a truncated path compared against an expected one is a
     * wrong answer rather than a near miss, so it is reported as unknown. */
    if (written == 0 || written >= sizeof path) { return; }

    copy_into(out, out_size, path);
}

#else

/* The module this process actually bound 'symbol_name' to, resolved to a
 * real filesystem path. Leaves "unknown" in place when that cannot be
 * established.
 *
 * Two lookups, tried in this order, because neither one is correct on both
 * platforms this file compiles for:
 *
 *   dladdr() on the address the compiler produced is the truthful answer on
 *   Mach-O. Measured on macOS 26.5.2 arm64 against a binary linked entirely
 *   against Homebrew's Khronos loader: dladdr(&clGetPlatformIDs) named that
 *   loader, while dlsym(RTLD_NEXT, "clGetPlatformIDs") named
 *   /System/Library/Frameworks/OpenCL.framework -- a library that process
 *   never calls into. RTLD_NEXT walks the flat image list rather than the
 *   two-level namespace binding the call itself goes through, so trusting it
 *   here would invent a substitution that is not happening and, worse, mask
 *   one that is.
 *
 *   On ELF that same address is usually not in the library at all. A
 *   function's address has to be unique process-wide, so the link editor
 *   plants a canonical PLT entry in the executable and every reference --
 *   including the shared library's own -- resolves to it. dladdr() then
 *   truthfully reports the verifier's own path, which answers a question
 *   nobody asked. That case is detected rather than assumed: dli_fbase is
 *   compared against the base dladdr() reports for a function defined in
 *   this file, and only a match sends the lookup to dlsym(RTLD_NEXT, ...),
 *   whose search order -- everything after the main executable, in load
 *   order -- is the same order the PLT entry itself resolves through.
 *
 * realpath() last. Both loaders report the path they opened, which on Linux
 * is typically the SONAME symlink (libclblast.so.1) and on macOS an install
 * name that may sit behind a symlinked prefix (/opt/homebrew/opt/... , or a
 * $TMPDIR whose real form carries a /private prefix). The caller compares
 * this against a path it recorded at install time, and only fully resolved
 * forms compare equal.
 */
static void resolve_module(void *address, const char *symbol_name,
                           char *out, size_t out_size)
{
    Dl_info info;
    Dl_info self;
    const char *path = NULL;
    char resolved[PATH_MAX];
    int have_self;

    have_self = dladdr((void *) (size_t) &resolve_module, &self);

    if (address != NULL
        && dladdr(address, &info) != 0
        && info.dli_fname != NULL
        && !(have_self != 0 && info.dli_fbase == self.dli_fbase))
    {
        path = info.dli_fname;
    }

    if (path == NULL)
    {
        void *bound = dlsym(RTLD_NEXT, symbol_name);

        if (bound != NULL && dladdr(bound, &info) != 0 && info.dli_fname != NULL)
        {
            path = info.dli_fname;
        }
    }

    if (path == NULL) { return; }

    /* An unresolvable path is still better than nothing -- it names a file
     * the loader claims to have opened -- so it is reported as-is and left
     * for the caller's comparison to reject. */
    if (realpath(path, resolved) != NULL) { copy_into(out, out_size, resolved); }
    else { copy_into(out, out_size, path); }
}

#endif

/* The full contract, printed exactly once on every exit path. */
static void report(const char *status, const char *error_text)
{
    printf("platform-name=%s\n", platform_name);
    printf("device-name=%s\n", device_name);
    printf("clblast-module=%s\n", clblast_module);
    printf("opencl-module=%s\n", opencl_module);
    printf("max-abs-error=%s\n", error_text);
    printf("verify-status=%s\n", status);
}

/* Prints the contract and returns the exit code that matches the given
 * status: 2 for "no-platform"/"no-device" (nothing to test on), 1 for
 * every other status (a real failure). */
static int bail(const char *status)
{
    report(status, "nan");
    if (strcmp(status, "no-platform") == 0 || strcmp(status, "no-device") == 0)
    {
        return EXIT_NOTHING_TO_TEST;
    }
    return 1;
}

/* Releases whichever OpenCL objects have actually been created; NULL
 * (not-yet-created, or already-failed) handles are skipped. Harmless to
 * omit since the process exits right after, but this file is meant to
 * model correct OpenCL usage. */
static void cleanup(cl_mem da, cl_mem db, cl_mem dc, cl_command_queue queue, cl_context ctx)
{
    if (da != NULL) { clReleaseMemObject(da); }
    if (db != NULL) { clReleaseMemObject(db); }
    if (dc != NULL) { clReleaseMemObject(dc); }
    if (queue != NULL) { clReleaseCommandQueue(queue); }
    if (ctx != NULL) { clReleaseContext(ctx); }
}

int main(void)
{
    cl_platform_id platform = NULL;
    cl_device_id device = NULL;
    cl_uint num_platforms = 0, num_devices = 0;
    cl_int err = CL_SUCCESS;
    cl_context ctx = NULL;
    cl_command_queue queue = NULL;
    cl_mem da = NULL, db = NULL, dc = NULL;
    cl_event ev = NULL;
    CLBlastStatusCode st;
    size_t i, j, k;
    double worst = 0.0;
    char status_text[64];
    char error_text[64];

    /* Resolved before the first OpenCL call: both libraries are load-time
     * dependencies of this program, so they are already mapped, and doing it
     * here means even the no-platform bail still reports which loader
     * returned no platforms. */
#if defined(_WIN32)
    resolve_module("clblast.dll", clblast_module, sizeof clblast_module);
    resolve_module("OpenCL.dll", opencl_module, sizeof opencl_module);
#else
    resolve_module((void *) (size_t) CLBlastSgemm, "CLBlastSgemm",
                   clblast_module, sizeof clblast_module);
    resolve_module((void *) (size_t) clGetPlatformIDs, "clGetPlatformIDs",
                   opencl_module, sizeof opencl_module);
#endif

    if (clGetPlatformIDs(1, &platform, &num_platforms) != CL_SUCCESS || num_platforms == 0)
    {
        return bail("no-platform");
    }

    /* Best effort: a runtime that refuses to name itself is not a reason to
     * fail a numeric check, and the buffers are pre-initialized to empty. */
    clGetPlatformInfo(platform, CL_PLATFORM_NAME,
                      sizeof platform_name, platform_name, NULL);
    flatten(platform_name);

    if (clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 1, &device, &num_devices) != CL_SUCCESS
        || num_devices == 0)
    {
        return bail("no-device");
    }

    clGetDeviceInfo(device, CL_DEVICE_NAME,
                    sizeof device_name, device_name, NULL);
    flatten(device_name);

    for (i = 0; i < (size_t)N * N; i++)
    {
        a[i] = (float)((int)(i % 7) - 3);
        b[i] = (float)((int)(i % 5) - 2);
        c[i] = 0.0f;
    }
    for (i = 0; i < N; i++)
    {
        for (j = 0; j < N; j++)
        {
            double sum = 0.0;
            for (k = 0; k < N; k++)
            {
                sum += (double)a[i * N + k] * (double)b[k * N + j];
            }
            ref[i * N + j] = (float)sum;
        }
    }

    ctx = clCreateContext(NULL, 1, &device, NULL, NULL, &err);
    if (err != CL_SUCCESS) { return bail("context-failed"); }

    /* clCreateCommandQueue rather than clCreateCommandQueueWithProperties:
     * ubuntu-22.04 ships PoCL 1.8, which reports OpenCL 1.2, where the
     * properties form does not exist. The deprecated call is present on
     * every version this action supports. */
    queue = clCreateCommandQueue(ctx, device, 0, &err);
    if (err != CL_SUCCESS) { cleanup(NULL, NULL, NULL, NULL, ctx); return bail("queue-failed"); }

    /* Checked individually, not just on the last call: if an earlier buffer
     * fails and a later one happens to succeed, the earlier failure must
     * not be missed and an invalid cl_mem must not be passed to CLBlast.
     * "buffer-failed" is its own status, distinct from "context-failed",
     * so a CI log points at buffer allocation rather than context
     * creation. */
    da = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof a, NULL, &err);
    if (err != CL_SUCCESS) { cleanup(NULL, NULL, NULL, queue, ctx); return bail("buffer-failed"); }
    db = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof b, NULL, &err);
    if (err != CL_SUCCESS) { cleanup(da, NULL, NULL, queue, ctx); return bail("buffer-failed"); }
    dc = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof c, NULL, &err);
    if (err != CL_SUCCESS) { cleanup(da, db, NULL, queue, ctx); return bail("buffer-failed"); }

    err = clEnqueueWriteBuffer(queue, da, CL_TRUE, 0, sizeof a, a, 0, NULL, NULL);
    if (err != CL_SUCCESS) { cleanup(da, db, dc, queue, ctx); return bail("queue-failed"); }
    err = clEnqueueWriteBuffer(queue, db, CL_TRUE, 0, sizeof b, b, 0, NULL, NULL);
    if (err != CL_SUCCESS) { cleanup(da, db, dc, queue, ctx); return bail("queue-failed"); }
    err = clEnqueueWriteBuffer(queue, dc, CL_TRUE, 0, sizeof c, c, 0, NULL, NULL);
    if (err != CL_SUCCESS) { cleanup(da, db, dc, queue, ctx); return bail("queue-failed"); }

    st = CLBlastSgemm(CLBlastLayoutRowMajor,
                      CLBlastTransposeNo, CLBlastTransposeNo,
                      N, N, N,
                      1.0f, da, 0, N, db, 0, N,
                      0.0f, dc, 0, N,
                      &queue, &ev);
    if (st != CLBlastSuccess)
    {
        cleanup(da, db, dc, queue, ctx);
        snprintf(status_text, sizeof status_text, "gemm-status-%d", (int)st);
        report(status_text, "nan");
        return 1;
    }
    if (ev != NULL) { clWaitForEvents(1, &ev); clReleaseEvent(ev); }
    clFinish(queue);
    err = clEnqueueReadBuffer(queue, dc, CL_TRUE, 0, sizeof c, c, 0, NULL, NULL);
    if (err != CL_SUCCESS) { cleanup(da, db, dc, queue, ctx); return bail("queue-failed"); }

    for (i = 0; i < (size_t)N * N; i++)
    {
        double d = fabs((double)c[i] - (double)ref[i]);
        if (!(d <= worst)) { worst = d; }   /* NaN-safe: NaN fails <= and wins */
    }

    cleanup(da, db, dc, queue, ctx);

    snprintf(error_text, sizeof error_text, "%.6g", worst);
    if (!(worst <= TOLERANCE))
    {
        report("wrong-result", error_text);
        return 1;
    }
    report("ok", error_text);
    return 0;
}

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
 * fp32 rounding (worst case here is ~1e-2 relative to values of order 1e3,
 * i.e. still exact) and catches only real breakage, never noise.
 */

#define CL_TARGET_OPENCL_VERSION 300
#define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#define CL_SILENCE_DEPRECATION

#include <stdio.h>
#include <math.h>
#include <CL/cl.h>
#include <clblast_c.h>

#define N 64
#define TOLERANCE 1e-3

/* Reported and exited-with when there is no device at all. Distinct from a
 * wrong answer: the action treats "nothing to test" and "tested and wrong"
 * differently, exactly as setup-opencl distinguishes device-count 0 from a
 * failed probe. */
#define EXIT_NOTHING_TO_TEST 2

static float a[N * N];
static float b[N * N];
static float c[N * N];
static float ref[N * N];

static int bail(const char *status)
{
    printf("max-abs-error=nan\n");
    printf("verify-status=%s\n", status);
    return EXIT_NOTHING_TO_TEST;
}

int main(void)
{
    cl_platform_id platform = NULL;
    cl_device_id device = NULL;
    cl_uint num_platforms = 0, num_devices = 0;
    cl_int err = CL_SUCCESS;
    cl_context ctx;
    cl_command_queue queue;
    cl_mem da, db, dc;
    cl_event ev = NULL;
    CLBlastStatusCode st;
    size_t i, j, k;
    double worst = 0.0;

    if (clGetPlatformIDs(1, &platform, &num_platforms) != CL_SUCCESS || num_platforms == 0)
    {
        return bail("no-platform");
    }
    if (clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 1, &device, &num_devices) != CL_SUCCESS
        || num_devices == 0)
    {
        return bail("no-device");
    }

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
    if (err != CL_SUCCESS) { return bail("queue-failed"); }

    da = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof a, NULL, &err);
    db = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof b, NULL, &err);
    dc = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof c, NULL, &err);
    if (err != CL_SUCCESS) { return bail("context-failed"); }

    clEnqueueWriteBuffer(queue, da, CL_TRUE, 0, sizeof a, a, 0, NULL, NULL);
    clEnqueueWriteBuffer(queue, db, CL_TRUE, 0, sizeof b, b, 0, NULL, NULL);
    clEnqueueWriteBuffer(queue, dc, CL_TRUE, 0, sizeof c, c, 0, NULL, NULL);

    st = CLBlastSgemm(CLBlastLayoutRowMajor,
                      CLBlastTransposeNo, CLBlastTransposeNo,
                      N, N, N,
                      1.0f, da, 0, N, db, 0, N,
                      0.0f, dc, 0, N,
                      &queue, &ev);
    if (st != CLBlastSuccess)
    {
        printf("max-abs-error=nan\n");
        printf("verify-status=gemm-status-%d\n", (int)st);
        return 1;
    }
    if (ev != NULL) { clWaitForEvents(1, &ev); clReleaseEvent(ev); }
    clFinish(queue);
    clEnqueueReadBuffer(queue, dc, CL_TRUE, 0, sizeof c, c, 0, NULL, NULL);

    for (i = 0; i < (size_t)N * N; i++)
    {
        double d = fabs((double)c[i] - (double)ref[i]);
        if (!(d <= worst)) { worst = d; }   /* NaN-safe: NaN fails <= and wins */
    }

    printf("max-abs-error=%.6g\n", worst);
    if (!(worst <= TOLERANCE))
    {
        printf("verify-status=wrong-result\n");
        return 1;
    }
    printf("verify-status=ok\n");
    return 0;
}

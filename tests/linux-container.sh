#!/usr/bin/env bash
#
# Runs the Linux install script and the GEMM verifier inside a container, so
# the Linux path can be exercised without pushing to CI.
#
# Usage: tests/linux-container.sh [image] [platform] [source]
#   image     defaults to ubuntu:24.04
#   platform  passed to --platform when non-empty, e.g. linux/amd64
#   source    defaults to package; the other documented value is build
#
# The container installs PoCL and an ICD loader itself rather than assuming
# setup-opencl already ran, then exports the same four variables that action
# exports. That keeps this test honest about the composition contract.

set -euo pipefail

image="${1:-ubuntu:24.04}"
platform="${2:-}"
source_mode="${3:-package}"

engine="docker"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || engine="podman"

platform_args=()
[ -n "${platform}" ] && platform_args=(--platform "${platform}")

"${engine}" run --rm ${platform_args[@]+"${platform_args[@]}"} \
    -v "$(pwd):/work:ro" -w /work \
    -e SC_SOURCE="${source_mode}" \
    -e SC_VERSION="${SC_VERSION:-}" \
    -e SC_COMMIT="${SC_COMMIT:-}" \
    "${image}" bash -c '
        set -euo pipefail
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            build-essential cmake git ca-certificates \
            opencl-headers ocl-icd-opencl-dev pocl-opencl-icd >/dev/null

        # Stand in for setup-opencl.
        export OpenCL_ROOT=/usr
        export OpenCL_INCLUDE_DIR=/usr/include
        export OpenCL_LIBRARY="$(find /usr/lib -name libOpenCL.so -print -quit)"
        export OPENCL_CPPFLAGS="-I/usr/include"
        export OPENCL_LIBS="-lOpenCL"
        export OCL_ICD_VENDORS=/etc/OpenCL/vendors/pocl.icd

        out="$(bash scripts/install-linux.sh)"
        printf "%s\n" "${out}"
        export CLBLAST_CPPFLAGS="$(printf "%s\n" "${out}" | sed -n "s/^clblast-cppflags=//p")"
        export CLBLAST_LIBS="$(printf "%s\n" "${out}" | sed -n "s/^clblast-libs=//p")"

        # The -lclblast in CLBLAST_LIBS is a link-time-only -L flag; the
        # dynamic loader still has to find libclblast.so.1 at run time. The
        # apt package lands under /usr/lib/<triplet>, already a default
        # search path, but a source build lands under RUNNER_TEMP (or /tmp),
        # which is not -- so this must be set unconditionally, not only on
        # the build leg, to keep both legs honest about what a real caller
        # (which likewise gets no rpath from clblast-libs) needs.
        libdir="$(dirname "$(printf "%s\n" "${out}" | sed -n "s/^clblast-library=//p")")"
        export LD_LIBRARY_PATH="${libdir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

        cd /tmp && cp -r /work/tests . && mkdir -p scripts \
            && cp /work/scripts/verify-gemm.c scripts/
        tests/verify-contract.sh ok
    '

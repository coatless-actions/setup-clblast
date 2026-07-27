#!/usr/bin/env bash
#
# Exercises the macOS source build end to end: a cold build, an assertion
# that the result is linked against the Khronos loader rather than Apple's
# framework, a numeric GEMM check, an assertion that the GEMM ran on the
# library and loader this script installed, and a second run that must be a
# fast no-op because the tree is already complete.
#
# The linkage assertion is the reason this action exists. Homebrew's clblast
# bottle links /System/Library/Frameworks/OpenCL.framework and exits 139
# (SIGSEGV) when loaded alongside the Khronos loader with PoCL. A build that
# silently resolves to the framework would pass a compile-and-link test and
# crash a consumer.
#
# otool answers what the file on disk says; the identity assertion answers
# what the running process did. Those come apart whenever something else on
# the search path satisfies the link first, so both are checked.
#
# WHAT THIS DOES NOT COVER
#
# The OpenCL environment below is a hand-built stand-in for setup-opencl's
# Homebrew path: two keg-only prefixes, a merged root, and PoCL's vendors
# directory inside its own keg. That is no longer what setup-opencl hands a
# macOS caller by default -- its 'pocl-source: auto' now resolves to
# conda-forge, which emits a self-contained $RUNNER_TEMP prefix, an include
# shim and an install name rewritten to be absolute. A pass here therefore
# says the source build is sound against the Homebrew composition, not that
# the default composition works; the workflow's macOS legs are what cover
# that, since they compose with the real setup-opencl@v1.
#
# Usage: tests/macos-build.sh [prefix]

set -euo pipefail

prefix="${1:-${TMPDIR:-/tmp}/setup-clblast-test}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

HOMEBREW_NO_AUTO_UPDATE=1 brew install --quiet opencl-headers opencl-icd-loader pocl

root="${TMPDIR:-/tmp}/setup-clblast-oclroot"
mkdir -p "${root}"
ln -sfn "$(brew --prefix opencl-headers)/include" "${root}/include"
ln -sfn "$(brew --prefix opencl-icd-loader)/lib" "${root}/lib"

export OpenCL_ROOT="${root}"
export OpenCL_INCLUDE_DIR="${root}/include"
export OpenCL_LIBRARY="${root}/lib/libOpenCL.dylib"
export OPENCL_CPPFLAGS="-I${root}/include"
export OPENCL_LIBS="-L${root}/lib -lOpenCL"
export OCL_ICD_VENDORS="$(brew --prefix pocl)/etc/OpenCL/vendors"
export SDKROOT="$(xcrun --show-sdk-path)"
export SC_PREFIX="${prefix}"

rm -rf "${prefix}"

printf '== cold build ==\n'
cold_start="$(date +%s)"
out="$(bash scripts/install-macos.sh)"
cold_end="$(date +%s)"
printf '%s\n' "${out}"
printf 'cold build took %s s\n' "$((cold_end - cold_start))"

library="$(printf '%s\n' "${out}" | sed -n 's/^clblast-library=//p')"
[ -e "${library}" ] || fail "clblast-library '${library}' does not exist"

printf '== linkage ==\n'
otool -L "${library}"
otool -L "${library}" | grep -q 'System/Library/Frameworks/OpenCL.framework' \
    && fail "libclblast is linked against Apple's OpenCL.framework; it will SIGSEGV alongside the Khronos loader"
otool -L "${library}" | grep -q 'libOpenCL' \
    || fail "libclblast is not linked against any OpenCL loader"

printf '== install name ==\n'
otool -D "${library}" | tail -1 | grep -q '^@rpath' \
    && fail "install name is still @rpath-relative; consumers linking -L...-lclblast will fail to load it"

export CLBLAST_CPPFLAGS="$(printf '%s\n' "${out}" | sed -n 's/^clblast-cppflags=//p')"
export CLBLAST_LIBS="$(printf '%s\n' "${out}" | sed -n 's/^clblast-libs=//p')"

printf '== numeric check (cold) ==\n'
tests/verify-contract.sh ok

# otool proved what the FILE on disk links against. This proves what the
# PROCESS bound to, which is a different question and the one a consumer
# actually depends on: a second libclblast or a second loader ahead of these
# on the search path would leave the otool output above unchanged and every
# number below correct.
printf '== identity (cold) ==\n'
SC_CLBLAST_LIBRARY="${library}" tests/assert-module-identity.sh --measure

printf '== warm run (must be a no-op) ==\n'
warm_start="$(date +%s)"
warm_out="$(bash scripts/install-macos.sh)"
warm_end="$(date +%s)"
warm="$((warm_end - warm_start))"
printf 'warm run took %s s\n' "${warm}"
[ "${warm}" -le 5 ] \
    || fail "warm run took ${warm} s; the completeness gate is not short-circuiting the build"

# A fast warm run only proves the build was skipped, not that what got
# skipped-to is correct. The project's own measurements show a warm PoCL
# kernel cache hides the SDKROOT-unset defect completely (CLBlastSgemm
# reports success with a garbage buffer on a cold cache, but a warm cache
# masks it), so "fast" is not "correct" and the cache-hit path gets the same
# numeric check the cold build did -- re-exporting the warm run's own
# emitted flags rather than reusing the cold run's, so a cache hit serving a
# wrong or stale tree cannot pass by riding the cold run's already-verified
# flags.
export CLBLAST_CPPFLAGS="$(printf '%s\n' "${warm_out}" | sed -n 's/^clblast-cppflags=//p')"
export CLBLAST_LIBS="$(printf '%s\n' "${warm_out}" | sed -n 's/^clblast-libs=//p')"

printf '== numeric check (warm) ==\n'
tests/verify-contract.sh ok

printf '== identity (warm) ==\n'
SC_CLBLAST_LIBRARY="$(printf '%s\n' "${warm_out}" | sed -n 's/^clblast-library=//p')" \
    tests/assert-module-identity.sh --measure

printf 'PASS: cold %ss, warm %ss, linked against the Khronos loader, numerics and library identity verified cold and warm\n' \
    "$((cold_end - cold_start))" "${warm}"

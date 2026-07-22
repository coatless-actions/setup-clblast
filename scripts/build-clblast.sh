#!/usr/bin/env bash
#
# Build and install CLBlast from source into SC_PREFIX. Shared by
# install-macos.sh (where it is the only option) and install-linux.sh (where
# it is the 'source: build' path).
#
# Two configure choices are load-bearing and both were measured, not guessed:
#
#   OPENCL_INCLUDE_DIRS / OPENCL_LIBRARIES  -- CLBlast ships its own
#     cmake/Modules/FindOpenCL.cmake which ignores CMake's standard
#     OpenCL_INCLUDE_DIR / OpenCL_LIBRARY entirely and reads these
#     all-uppercase plural names instead. find_path and find_library are
#     no-ops when their result variable already holds a value, so presetting
#     them bypasses the search. Passing the CMake-standard names instead
#     silently resolves to Apple's OpenCL.framework on macOS, and a library
#     linked against that SIGSEGVs when loaded alongside the Khronos loader.
#
#   CMAKE_INSTALL_NAME_DIR -- without it the install name stays
#     @rpath/libclblast.1.dylib and a consumer that links
#     '-L<prefix>/lib -lclblast' links cleanly and then dies at load with
#     "no LC_RPATH's found". Setting it makes the install name absolute so no
#     consumer rpath is needed. Harmless on Linux, where it is ignored.
#
# TUNERS defaults to ON upstream and roughly doubles the build; it is the one
# option worth turning off. CMAKE_POLICY_VERSION_MINIMUM is required for
# CLBlast <= 1.6.3, which declares cmake_minimum_required(VERSION 2.8.11) and
# is rejected outright by CMake 4.x, and is harmless on 1.7.0.

set -euo pipefail

version="${SC_VERSION:?SC_VERSION is required}"
commit="${SC_COMMIT:?SC_COMMIT is required}"
prefix="${SC_PREFIX:?SC_PREFIX is required}"
opencl_include="${SC_OPENCL_INCLUDE_DIRS:?SC_OPENCL_INCLUDE_DIRS is required}"
opencl_library="${SC_OPENCL_LIBRARIES:?SC_OPENCL_LIBRARIES is required}"

# All build chatter goes to stderr. The caller captures stdout as a
# key=value contract and a stray cmake progress line would poison it.
exec 3>&1
exec 1>&2

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

git clone --quiet --depth 1 --branch "${version}" \
    https://github.com/CNugteren/CLBlast.git "${work}/src"

# A tag is a mutable ref: upstream can move it, and a shallow clone would
# follow it without complaint. The pinned commit is what actually fixes the
# content, and it is the source-build equivalent of the SHA-256 digest the
# Windows path checks. Fail closed, never warn and continue.
actual="$(git -C "${work}/src" rev-parse HEAD)"
if [ "${actual}" != "${commit}" ]; then
    echo "::error::CLBlast tag '${version}' resolved to commit ${actual}, expected ${commit}"
    echo "The upstream tag was moved, or the checkout was tampered with in transit. Do not trust this tree. If upstream genuinely re-tagged the release, verify the new commit out of band before updating the pin in scripts/install-macos.sh."
    exit 1
fi

cmake -S "${work}/src" -B "${work}/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DTUNERS=OFF -DSAMPLES=OFF -DTESTS=OFF -DCLIENTS=OFF -DNETLIB=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_INSTALL_NAME_DIR="${prefix}/lib" \
    -DOPENCL_INCLUDE_DIRS="${opencl_include}" \
    -DOPENCL_LIBRARIES="${opencl_library}" \
    -DCMAKE_INSTALL_PREFIX="${prefix}"

jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
cmake --build "${work}/build" --parallel "${jobs}" --target install

exec 1>&3 3>&-

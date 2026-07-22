#!/usr/bin/env bash
#
# Install CLBlast on Debian-family Linux, then print the resulting paths as
# key=value lines.
#
# 'package' installs libclblast-dev by name and never version-pins, so the
# action rolls forward when ubuntu-latest moves: jammy 1.5.2, noble 1.6.2,
# questing 1.6.3, resolute 1.6.3, stonking 1.7.0. Every suite from jammy
# publishes amd64 and arm64, so both GitHub-hosted Linux arches are covered.
#
# 'build' compiles the pinned release with the shared build script instead.
#
# libclblast-dev depends on 'ocl-icd-opencl-dev | opencl-dev', so apt may
# pull in an ICD loader. That is the same package setup-opencl already
# installs, so it is a no-op in the composed case -- but this script does not
# assume setup-opencl ran and never relies on that dependency to supply the
# loader.

set -euo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }

# Written to stderr, not stdout: action.yml captures this script's whole
# stdout via command substitution and only replays it after the substitution
# succeeds. Under 'set -e' a non-zero exit aborts before the replay, so a
# stdout-only message would reach neither the log nor an annotation.
die() {
    echo "::error::$1" >&2
    echo "$2" >&2
    exit 1
}

command -v apt-get >/dev/null 2>&1 \
    || die "apt-get not found" \
           "This install script supports Debian-family Linux images only. Use a Debian-family base image (e.g. 'ubuntu:24.04') for 'container:' jobs, or install CLBlast yourself before this step."

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    die "sudo not found" \
        "This install script needs root privileges to run apt-get. Most 'container:' jobs already run as root (id 0), which needs no sudo at all; otherwise, use a base image that includes sudo."
fi

source_mode="${SC_SOURCE:-package}"
sudo_cmd=""
[ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"

multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo '')"

if [ "${source_mode}" = "build" ]; then
    prefix="${SC_PREFIX:-${RUNNER_TEMP:-/tmp}/clblast}"

    # cmake and git are not guaranteed inside a 'container:' job, and neither
    # is on the ubuntu runner images' critical path for anything else this
    # script does -- install them only on the branch that needs them.
    # shellcheck disable=SC2086
    ${sudo_cmd} env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086
    ${sudo_cmd} env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        --no-install-recommends cmake git ca-certificates

    SC_PREFIX="${prefix}" \
    SC_OPENCL_INCLUDE_DIRS="${OpenCL_INCLUDE_DIR:-/usr/include}" \
    SC_OPENCL_LIBRARIES="${OpenCL_LIBRARY:-$(find /usr/lib -name 'libOpenCL.so' -print -quit)}" \
        bash "$(dirname "$0")/build-clblast.sh"

    # ${prefix}/lib is not on the default loader search path (it is
    # RUNNER_TEMP or /tmp, unlike the apt package's /usr/lib/<triplet>
    # below), so a consumer that only uses '-L${prefix}/lib -lclblast' links
    # cleanly and then dies at load with "cannot open shared object file".
    # There is no ELF equivalent of CMAKE_INSTALL_NAME_DIR that would let
    # libclblast.so.1's own build fix this for every consumer -- an RPATH
    # baked into the library only governs how *it* resolves *its own*
    # dependencies, never how a consumer locates the library itself. The
    # fix has to live on the consumer's side of the boundary: -Wl,-rpath
    # here lands an RPATH on whatever binary a caller links with this flag
    # string, exactly like -L and -l already do.
    emit clblast-root           "${prefix}"
    emit clblast-include-dir    "${prefix}/include"
    emit clblast-library        "${prefix}/lib/libclblast.so"
    emit clblast-cppflags       "-I${prefix}/include"
    emit clblast-libs           "-L${prefix}/lib -Wl,-rpath,${prefix}/lib -lclblast"
    emit clblast-cmake-dir      "${prefix}/lib/cmake/CLBlast"
    emit clblast-pkgconfig-dir  "${prefix}/lib/pkgconfig"
    emit clblast-version        "${SC_VERSION}"
    emit source-used            "build"
    exit 0
fi

# shellcheck disable=SC2086
${sudo_cmd} env DEBIAN_FRONTEND=noninteractive apt-get update -qq
# shellcheck disable=SC2086
${sudo_cmd} env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    --no-install-recommends libclblast-dev

libdir="/usr/lib/${multiarch}"
library="${libdir}/libclblast.so"
[ -e "${library}" ] || library="$(find /usr/lib -name 'libclblast.so' -print -quit)"
[ -n "${library}" ] \
    || die "libclblast.so not found after installing libclblast-dev" \
           "The package layout may have changed. Inspect 'dpkg -L libclblast-dev' on this image, or use 'source: build'."

# dpkg-query reports e.g. '1.6.2-1'; strip the Debian revision so the
# reported version is upstream's, which is what a caller comparing against
# CLBlast release numbers expects.
version="$(dpkg-query -W -f='${Version}' libclblast-dev 2>/dev/null | sed 's/-[^-]*$//')"

emit clblast-root           "/usr"
emit clblast-include-dir    "/usr/include"
emit clblast-library        "${library}"
emit clblast-cppflags       "-I/usr/include"
emit clblast-libs           "-lclblast"
emit clblast-cmake-dir      "${libdir}/cmake/CLBlast"
emit clblast-pkgconfig-dir  "${libdir}/pkgconfig"
emit clblast-version        "${version}"
emit source-used            "package"

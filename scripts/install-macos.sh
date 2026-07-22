#!/usr/bin/env bash
#
# Build and install CLBlast from source on macOS, then print the resulting
# paths as key=value lines.
#
# A source build is not a preference here, it is the only correct option.
# Homebrew's clblast bottle links /System/Library/Frameworks/OpenCL.framework
# (its formula declares no loader dependency at all). Loading that bottle in
# the same process as the Khronos opencl-icd-loader, with OCL_ICD_VENDORS
# pointed at PoCL, gives SIGSEGV -- reproduced on macOS 26.5.1 arm64, not
# theorized. 'source: package' on macOS is therefore rejected by action.yml
# before this script ever runs.
#
# The whole install tree is the cache unit. The completeness gate below is a
# check on every file a consumer actually needs, not a Test-Path on one of
# them: a partial restore that satisfies a single-file check would be used
# as-is and fail later at link or load time, while a gate that is too strict
# in the other direction would silently rebuild on every run forever.
#
# Existing files are necessary but not sufficient. A prefix reused across a
# different SC_VERSION / SC_COMMIT / OpenCL_ROOT -- a non-ephemeral
# self-hosted runner, or an actions/cache restore-keys prefix-fallback hit --
# would still contain every file the gate looks for, just the WRONG ones,
# and the script would report the newly requested version while shipping the
# old binary underneath. A stamp file recording exactly what produced the
# tree closes that gap: the tree is reusable only when the stamp matches
# everything currently requested.

set -euo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }

die() {
    echo "::error::$1" >&2
    echo "$2" >&2
    exit 1
}

version="${SC_VERSION:-1.7.0}"
commit="${SC_COMMIT:-ca2fc3cb09d4917cc72d4ca661d30296865a4afc}"
prefix="${SC_PREFIX:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/clblast}"

[ -n "${OpenCL_ROOT:-}" ] \
    || die "OpenCL_ROOT is not set" \
           "setup-clblast builds against the ICD loader that setup-opencl installed, and refuses to guess. Add 'uses: coatless-actions/setup-opencl@v1' before this step."

opencl_include="${OpenCL_INCLUDE_DIR:-${OpenCL_ROOT}/include}"
opencl_library="${OpenCL_LIBRARY:-${OpenCL_ROOT}/lib/libOpenCL.dylib}"

[ -e "${opencl_include}/CL/cl.h" ] \
    || die "No CL/cl.h under '${opencl_include}'" \
           "OpenCL_INCLUDE_DIR does not point at a usable header tree. Confirm setup-opencl ran and did not have its exports overridden by the caller."
[ -e "${opencl_library}" ] \
    || die "OpenCL loader '${opencl_library}' does not exist" \
           "OpenCL_LIBRARY does not point at a real loader. Confirm setup-opencl ran and did not have its exports overridden by the caller."

case "${opencl_library}" in
    *OpenCL.framework*)
        die "OpenCL_LIBRARY points at Apple's OpenCL.framework" \
            "A CLBlast built against Apple's framework segfaults when loaded alongside the Khronos ICD loader. Use setup-opencl's default (PoCL and the Khronos loader) rather than 'runtime: apple'."
        ;;
esac

# RcppBandicoot's configure.ac prefers "$(brew --prefix)/opt/clblast" when it
# exists, over anything CLBLAST_CPPFLAGS says -- and that keg is exactly the
# framework-linked bottle this script exists to avoid. Surface it rather than
# letting a downstream build silently pick the wrong library. A warning and
# not an error: the action did not install that keg, another formula may have
# pulled it in, and failing a job over a package this action does not own is
# over-reach.
if [ -d "$(brew --prefix 2>/dev/null)/opt/clblast" ]; then
    echo "::warning::A Homebrew 'clblast' keg is installed on this runner. Its libclblast.dylib links Apple's OpenCL.framework and will SIGSEGV alongside the Khronos loader. Build systems that probe Homebrew prefixes directly (RcppBandicoot's configure.ac does) may find it instead of the library this action installed. Run 'brew uninstall --ignore-dependencies clblast' if that applies to your build." >&2
fi

# Complete-tree gate. Every file below is one a consumer reaches for:
# the C header the compile line resolves, the versioned dylib the link line
# resolves, the unversioned symlink '-lclblast' resolves, the CMake package
# config, and the pkg-config file. A tree missing any one of them is not a
# cache hit.
files_complete() {
    [ -e "${prefix}/include/clblast_c.h" ] \
        && [ -e "${prefix}/lib/libclblast.dylib" ] \
        && [ -e "${prefix}/lib/libclblast.1.dylib" ] \
        && [ -e "${prefix}/lib/cmake/CLBlast/CLBlastConfig.cmake" ] \
        && [ -e "${prefix}/lib/pkgconfig/clblast.pc" ]
}

# Identity stamp, written after a successful build (below). Records exactly
# what produced the tree at 'prefix': the version, the commit, and the
# resolved OpenCL inputs that were actually passed to build-clblast.sh. A
# tree is only a cache hit when every file is present AND this matches
# everything currently requested -- so a changed version, commit, or
# OpenCL_ROOT can never be satisfied by an existing tree, even if that tree
# is otherwise byte-for-byte complete.
stamp_file="${prefix}/.setup-clblast-stamp"
stamp_wanted="$(printf 'version=%s\ncommit=%s\nopencl-include=%s\nopencl-library=%s\n' \
    "${version}" "${commit}" "${opencl_include}" "${opencl_library}")"

stamp_matches() {
    [ -e "${stamp_file}" ] && [ "$(cat "${stamp_file}")" = "${stamp_wanted}" ]
}

tree_is_complete() {
    files_complete && stamp_matches
}

if ! tree_is_complete; then
    rm -rf "${prefix}"
    SC_VERSION="${version}" \
    SC_COMMIT="${commit}" \
    SC_PREFIX="${prefix}" \
    SC_OPENCL_INCLUDE_DIRS="${opencl_include}" \
    SC_OPENCL_LIBRARIES="${opencl_library}" \
        bash "$(dirname "$0")/build-clblast.sh"

    # Re-run the file half of the same gate used for the cache decision.
    # Without this, a layout change that drops one required file would not
    # fail loudly -- it would make every future run look like a cache miss
    # forever, rebuilding on every single run with no error.
    files_complete \
        || die "Installed CLBlast tree at '${prefix}' is missing one of: include/clblast_c.h, lib/libclblast.dylib, lib/libclblast.1.dylib, lib/cmake/CLBlast/CLBlastConfig.cmake, lib/pkgconfig/clblast.pc" \
               "The upstream install layout may have changed for CLBlast ${version}. Check https://github.com/CNugteren/CLBlast/releases/tag/${version}."

    # Only written once the tree is known-complete for exactly this
    # identity, so a failed or partial build never leaves behind a stamp
    # that would make the next run trust it.
    printf '%s' "${stamp_wanted}" > "${stamp_file}"
fi

emit clblast-root           "${prefix}"
emit clblast-include-dir    "${prefix}/include"
emit clblast-library        "${prefix}/lib/libclblast.dylib"
emit clblast-cppflags       "-I${prefix}/include"
# The rpath flag is belt and braces: build-clblast.sh sets
# CMAKE_INSTALL_NAME_DIR so the install name is already absolute. Emitting it
# anyway costs nothing and keeps the link line correct if a future consumer
# copies the tree somewhere else.
emit clblast-libs           "-L${prefix}/lib -lclblast -Wl,-rpath,${prefix}/lib"
emit clblast-cmake-dir      "${prefix}/lib/cmake/CLBlast"
emit clblast-pkgconfig-dir  "${prefix}/lib/pkgconfig"
emit clblast-version        "${version}"
emit source-used            "build"

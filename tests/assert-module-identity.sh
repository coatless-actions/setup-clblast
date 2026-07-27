#!/usr/bin/env bash
#
# Asserts that the GEMM really ran on the CLBlast and the ICD loader that
# were installed for it, and not on some other copy that satisfied the link
# or the loader search first.
#
# Every other assertion this repository makes is satisfied by "a correct GEMM
# happened". That is a weaker claim than it looks, because two search orders
# in this action's own supported configurations can hand the process a
# different library without anything going wrong on the way:
#
#   install-linux.sh's package branch emits a bare '-lclblast' with no -L at
#   all, so any libclblast anywhere on the default search path satisfies the
#   link, and the dynamic loader then picks by SONAME with no reference to
#   which one was meant.
#
#   Windows resolves clblast.dll and OpenCL.dll through the PE search order,
#   which consults the application directory and System32 before it ever
#   reaches PATH -- so the loader a caller put on PATH is the LAST candidate
#   considered, not the first, and Windows ships its own OpenCL.dll in
#   System32.
#
# Either substitution produces a perfectly correct 64x64 SGEMM and leaves
# every numeric assertion green. This script is what makes it visible.
#
# Usage: tests/assert-module-identity.sh [--measure]
#
# What was supposed to be installed always comes from the environment:
#
#   SC_CLBLAST_LIBRARY  the action's clblast-library output (non-Windows)
#   SC_CLBLAST_ROOT     the action's clblast-root output (Windows only)
#   OpenCL_LIBRARY      exported by setup-opencl (non-Windows)
#   OpenCL_ROOT         exported by setup-opencl (Windows only)
#
# What actually ran comes from one of two places, chosen explicitly rather
# than inferred:
#
#   default    SC_CLBLAST_MODULE and SC_OPENCL_MODULE must be set and
#              non-empty. This is the workflow's mode: a 'uses:' step's
#              stdout cannot be piped into a later step, so reading the
#              action's own outputs is the only way to assert on what the
#              action itself measured.
#
#   --measure  this script compiles scripts/verify-gemm.c against
#              CLBLAST_CPPFLAGS, CLBLAST_LIBS, OPENCL_CPPFLAGS and
#              OPENCL_LIBS -- exactly what a consumer gets -- and reads the
#              keys off its own run. This is the local harnesses' mode; they
#              have no action outputs to read. Requires the repository root
#              as the working directory.
#
# The mode is a flag and not "measure when the two variables happen to be
# empty", because empty is exactly what the outputs hold when the action ran
# with verify: false. Inferring would turn that into a silent switch to
# measuring, and a check that quietly re-measures what it was asked to
# verify is not a check.
#
# Diagnostics are written as ::error:: annotations, which render in the
# Actions UI and read as ordinary text anywhere else.

set -euo pipefail

fail() {
    echo "::error::$1" >&2
    echo "$2" >&2
    exit 1
}

mode="compare"
case "${1:-}" in
    '')         ;;
    --measure)  mode="measure" ;;
    *)
        printf 'usage: tests/assert-module-identity.sh [--measure]\n' >&2
        exit 1
        ;;
esac

# RUNNER_OS is absent when this runs outside Actions; derive the same three
# values from uname so a local run behaves identically.
os="${RUNNER_OS:-}"
if [ -z "${os}" ]; then
    case "$(uname -s)" in
        Darwin)               os="macOS" ;;
        MINGW*|MSYS*|CYGWIN*) os="Windows" ;;
        *)                    os="Linux" ;;
    esac
fi

if [ "${mode}" = "compare" ]; then
    # ':?' rather than ':-': it rejects empty as well as unset, which is what
    # makes a verify: false run fail here instead of being compared against
    # nothing.
    got_clblast="${SC_CLBLAST_MODULE:?SC_CLBLAST_MODULE is required without --measure}"
    got_opencl="${SC_OPENCL_MODULE:?SC_OPENCL_MODULE is required without --measure}"
    # Windows asserts the platform instead of the loader (see below); the
    # workflow exports both names beside the module paths.
    got_platform="${SC_PLATFORM_NAME:-}"
    expected_platform="${SC_EXPECT_PLATFORM:-}"
else
    workdir="$(mktemp -d)"
    trap 'rm -rf "${workdir}"' EXIT

    # 'cc' is absent on Windows runners, which ship mingw 'gcc' on PATH.
    compiler="cc"
    command -v cc >/dev/null 2>&1 || compiler="gcc"

    # dladdr lives in libdl on glibc before 2.34 and in libc from 2.34
    # onward, where -ldl remains an empty stub. There is no libdl on macOS or
    # under mingw, so this is added on Linux only.
    extra_libs=""
    if [ "$(uname -s)" = "Linux" ]; then
        extra_libs="-ldl"
    fi

    # shellcheck disable=SC2086
    "${compiler}" -O2 -o "${workdir}/verify" scripts/verify-gemm.c \
        ${CLBLAST_CPPFLAGS:-} ${OPENCL_CPPFLAGS:-} \
        ${CLBLAST_LIBS:-} ${OPENCL_LIBS:-} ${extra_libs} -lm \
        || fail "verify-gemm.c did not compile against the exported flags" \
                "The identity check compiles the verifier the same way a consumer would. A failure here is a broken CLBLAST_CPPFLAGS/CLBLAST_LIBS export, not an identity problem."

    # The exit status is the numeric verdict, which tests/verify-contract.sh
    # owns; only the identity keys are read here.
    keys="$("${workdir}/verify" || true)"
    printf '%s\n' "${keys}"

    got_clblast="$(printf '%s\n' "${keys}" | sed -n 's/^clblast-module=//p')"
    got_opencl="$(printf '%s\n' "${keys}" | sed -n 's/^opencl-module=//p')"
    got_platform="$(printf '%s\n' "${keys}" | sed -n 's/^platform-name=//p')"
    expected_platform="${SC_EXPECT_PLATFORM:-}"
fi

# Both sides of every comparison go through this, never raw strings. The
# pairs below all name the same file and would all fail a string comparison:
#
#   Linux    the loader opens the SONAME symlink (libclblast.so.1) while the
#            action emits the development symlink (libclblast.so), and /lib
#            is itself a symlink to /usr/lib on a usrmerge image.
#   macOS    the emitted libclblast.dylib is a symlink to libclblast.1.dylib
#            to libclblast.1.7.0.dylib, and a $TMPDIR prefix resolves to a
#            /private form.
#   Windows  drive letters and separators vary in spelling and the file
#            system is case-insensitive.
#
# Falls back to the input when a path cannot be resolved -- a path that does
# not exist, or the verifier's own "unknown" -- so the comparison still runs,
# still fails, and still shows the unresolvable value.
canon() {
    case "${os}" in
        Windows)
            # Git Bash's realpath cannot read a C:\... path at all. cygpath -u
            # accepts either spelling and -m -a returns one absolute
            # forward-slash form.
            #
            # The fallback sits inside the substitution, not after the tr
            # pipeline: '|| ...' attached to a pipeline tests the LAST
            # command's status, and tr always succeeds, so a failing cygpath
            # would otherwise yield an empty string rather than the raw path.
            local converted
            converted="$(cygpath -m -a "$(cygpath -u "$1" 2>/dev/null)" 2>/dev/null || printf '%s' "$1")"
            # Folded because Windows paths are case-insensitive.
            printf '%s\n' "${converted}" | tr '[:upper:]' '[:lower:]'
            ;;
        *)
            realpath "$1" 2>/dev/null || printf '%s\n' "$1"
            ;;
    esac
}

case "${os}" in
    Windows)
        # clblast-library names the COFF import library the link line
        # resolves; the module the process actually maps is the DLL beside
        # it, which is what the verifier reports. Same split for the loader:
        # OpenCL_LIBRARY is OpenCL.lib, and OpenCL.dll lives in
        # OpenCL_ROOT/bin.
        expected_clblast="${SC_CLBLAST_ROOT:?SC_CLBLAST_ROOT is required on Windows}/bin/clblast.dll"
        expected_opencl="${OpenCL_ROOT:?OpenCL_ROOT is not set; setup-opencl must run before this}/bin/OpenCL.dll"
        ;;
    *)
        expected_clblast="${SC_CLBLAST_LIBRARY:?SC_CLBLAST_LIBRARY is required}"
        expected_opencl="${OpenCL_LIBRARY:?OpenCL_LIBRARY is not set; setup-opencl must run before this}"
        ;;
esac

printf 'clblast-module = %s\n' "${got_clblast}"
printf '      expected = %s\n' "${expected_clblast}"
printf 'opencl-module  = %s\n' "${got_opencl}"
printf '      expected = %s\n' "${expected_opencl}"

# "unknown" is the verifier's own word for "I could not establish this". It
# is rejected separately from a mismatch because the two mean different
# things: a mismatch is a substituted library, while "unknown" means this
# check saw nothing at all and so proves nothing either way.
for value in "${got_clblast}" "${got_opencl}"; do
    if [ -z "${value}" ] || [ "${value}" = "unknown" ]; then
        fail "The verifier could not determine which library it was bound to (got '${value}')" \
             "Nothing in this run proves the GEMM used the CLBlast or the loader that were installed for it. The verifier's own output above names which of the two keys is unknown; on a platform where dladdr or GetModuleHandleA cannot see the module, this check has to be fixed before it can be trusted."
    fi
done

if [ "$(canon "${got_clblast}")" != "$(canon "${expected_clblast}")" ]; then
    fail "The GEMM ran on CLBlast '${got_clblast}', not the '${expected_clblast}' that was installed for it" \
         "Resolved forms compared: '$(canon "${got_clblast}")' against '$(canon "${expected_clblast}")'. Another CLBlast satisfied the link or the loader search first. On Linux that is what a bare '-lclblast' with no -L invites when a second copy sits on the default search path; on Windows the PE search order reaches the application directory and System32 before PATH. The numbers this run produced are correct, and they say nothing whatever about the library this action installed."
fi

# The loader is asserted everywhere EXCEPT Windows, and the exception is a
# statement about Windows rather than a concession.
#
# Windows ships its own ICD loader at System32\OpenCL.dll, and the PE search
# order reaches System32 before PATH, so that is what binds no matter what
# setup-opencl puts on PATH. That is also the right answer: an ICD loader is
# the OS's dispatch layer, vendor runtimes register themselves with it under
# HKLM, and deliberately binding a second loader alongside it is the hazard
# this pair of actions refuses elsewhere -- it is exactly why Homebrew's
# CLBlast bottle is rejected on macOS. The Khronos loader this action installs
# on Windows earns its keep at BUILD time, supplying the headers and the import
# library; it is not meant to win at run time.
#
# What still has to be proved on Windows is the same claim by another route:
# that the arithmetic ran on the runtime that was installed for it. The
# platform name carries that, since the device comes from the vendor ICD the
# loader dispatched to. Note the consequence for setup-opencl, which is worth
# knowing rather than discovering later: OCL_ICD_FILENAMES is a Khronos-loader
# variable, so on Windows it is inert, and pinning the runtime works because
# the installer registers the DLL in HKLM -- not because of that export.
if [ "${os}" = "Windows" ]; then
    # Empty is rejected before the comparison, and separately from a
    # mismatch, for the same reason "unknown" is above: a mismatch means the
    # wrong runtime served the GEMM, while empty means this check saw nothing
    # and proves nothing. Comparing it anyway reports the wrong diagnosis --
    # "ran on platform ''" reads as a substituted runtime when the real fault
    # is that the workflow did not pass the name through.
    if [ -n "${expected_platform:-}" ] && [ -z "${got_platform}" ]; then
        fail "The verifier reported no OpenCL platform name, so the runtime it used cannot be established" \
             "SC_PLATFORM_NAME reached this script empty. On Windows the loader path proves nothing (the OS dispatcher is bound by design), so the platform is the only evidence of which runtime ran, and without it this check asserts nothing at all. Confirm the calling step exports SC_PLATFORM_NAME from the action's platform-name output."
    fi

    if [ -z "${expected_platform:-}" ]; then
        printf 'loader identity not asserted on Windows; platform is %s\n' "${got_platform:-unknown}"
    elif ! printf '%s' "${got_platform}" | tr '[:upper:]' '[:lower:]' \
             | grep -qF "$(printf '%s' "${expected_platform}" | tr '[:upper:]' '[:lower:]')"; then
        fail "The GEMM ran on OpenCL platform '${got_platform}', not the '${expected_platform}' that was installed for it" \
             "On Windows the ICD loader is the OS's own (System32\\OpenCL.dll) and binding it is correct, so the loader path proves nothing here. The platform does: it names the vendor runtime the loader dispatched to, and a mismatch means the GEMM ran on some other OpenCL implementation already registered on the machine."
    else
        printf 'loader is the OS ICD dispatcher, as expected on Windows; platform = %s\n' "${got_platform}"
    fi
elif [ "$(canon "${got_opencl}")" != "$(canon "${expected_opencl}")" ]; then
    fail "The GEMM ran on ICD loader '${got_opencl}', not the '${expected_opencl}' setup-opencl installed" \
         "Resolved forms compared: '$(canon "${got_opencl}")' against '$(canon "${expected_opencl}")'. On macOS it means Apple's OpenCL.framework was bound instead of the Khronos loader, the configuration this action already refuses for CLBlast itself. On Linux a second loader on the default search path won the link. Either way the device enumeration, the ICD lookup and the kernel compiler all belong to a loader nobody chose."
fi

printf 'PASS: the GEMM ran on the CLBlast and the ICD loader that were installed for it\n'

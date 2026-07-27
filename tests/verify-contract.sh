#!/usr/bin/env bash
#
# Asserts the GEMM verifier's output contract: six keys, a numeric
# max-abs-error, a verify-status drawn from the documented set, and two
# module paths naming what the process was actually bound to. Run from the
# repository root.
#
# Usage: tests/verify-contract.sh [expected-status]
#   expected-status defaults to ok. Pass no-device to assert the
#   nothing-to-test path, or wrong-result to assert a known-bad setup is
#   actually caught.
#
# Compiles against CLBLAST_CPPFLAGS / CLBLAST_LIBS / OPENCL_CPPFLAGS /
# OPENCL_LIBS from the environment -- the same four variables a consumer
# uses -- so a pass here means the exported contract works, not merely that
# some library somewhere is installed.
#
# This checks the SHAPE of the identity keys, never which paths they should
# hold: only the caller knows which CLBlast and which loader were supposed to
# win. tests/macos-build.sh and the workflow's own steps do that comparison.
# Shape is still worth asserting on its own -- "unknown" means the verifier
# could not establish what it was bound to, and an identity check that cannot
# see its subject is not evidence of anything.

set -uo pipefail

expected="${1:-ok}"
case "${expected}" in
    ok|wrong-result|no-platform|no-device|context-failed|queue-failed|buffer-failed) ;;
    *)
        printf 'FAIL: unknown expected-status "%s"\n' "${expected}" >&2
        exit 1
        ;;
esac

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 'cc' is absent on Windows runners, which ship mingw 'gcc' on PATH instead.
compiler="cc"
command -v cc >/dev/null 2>&1 || compiler="gcc"
command -v "${compiler}" >/dev/null 2>&1 || fail "no C compiler ('cc' or 'gcc') on PATH"

# dladdr lives in libdl on glibc before 2.34 and in libc from 2.34 onward,
# where -ldl is a harmless empty stub kept for exactly this reason. There is
# no libdl at all on macOS (dladdr is in libSystem) or under mingw, so the
# flag is added on Linux only rather than unconditionally.
extra_libs=""
if [ "$(uname -s)" = "Linux" ]; then
    extra_libs="-ldl"
fi

# shellcheck disable=SC2086
"${compiler}" -O2 -o "${workdir}/verify" scripts/verify-gemm.c \
    ${CLBLAST_CPPFLAGS:-} ${OPENCL_CPPFLAGS:-} \
    ${CLBLAST_LIBS:-} ${OPENCL_LIBS:-} ${extra_libs} -lm \
    || fail "verify-gemm.c did not compile against the exported flags"

output="$("${workdir}/verify")"
status=$?

for key in platform-name device-name clblast-module opencl-module \
           max-abs-error verify-status; do
    printf '%s\n' "${output}" | grep -q "^${key}=" \
        || fail "missing key '${key}' in output:
${output}"
done

err="$(printf '%s\n' "${output}" | sed -n 's/^max-abs-error=//p')"
case "${err}" in
    ''|*[!0-9.eE+inaf-]*) fail "max-abs-error '${err}' is not numeric or nan" ;;
esac

# An absolute path, on either a POSIX or a Windows spelling. "unknown" is the
# verifier's own word for "I could not establish this", and it is called out
# separately because the two failures have nothing to do with each other: a
# non-absolute path means the loader reported something unexpected, while
# "unknown" means the lookup itself did not work on this platform.
for key in clblast-module opencl-module; do
    value="$(printf '%s\n' "${output}" | sed -n "s/^${key}=//p")"
    [ "${value}" != "unknown" ] \
        || fail "${key} is 'unknown': the verifier could not determine which library it was bound to, so nothing here proves which CLBlast or which loader ran"
    case "${value}" in
        /*|?:[/\\]*) ;;
        *) fail "${key} '${value}' is not an absolute path" ;;
    esac
done

got="$(printf '%s\n' "${output}" | sed -n 's/^verify-status=//p')"
[ "${got}" = "${expected}" ] \
    || fail "verify-status '${got}' does not match expected '${expected}'
${output}"

# Exit codes are part of the contract: 0 only for ok, 2 only when there was
# nothing to test on. Asserting these keeps action.yml free to branch on the
# code rather than re-parsing the text.
case "${expected}" in
    ok)
        [ "${status}" -eq 0 ] || fail "expected exit 0 for ok, got ${status}" ;;
    no-platform|no-device)
        [ "${status}" -eq 2 ] || fail "expected exit 2 for ${expected}, got ${status}" ;;
    *)
        [ "${status}" -eq 1 ] || fail "expected exit 1 for ${expected}, got ${status}" ;;
esac

printf 'PASS: %s\n' "$(printf '%s\n' "${output}" | tr '\n' ' ')"

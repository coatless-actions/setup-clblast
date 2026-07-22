#!/usr/bin/env bash
#
# Asserts the GEMM verifier's output contract: two keys, a numeric
# max-abs-error, and a verify-status drawn from the documented set. Run from
# the repository root.
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

set -uo pipefail

expected="${1:-ok}"
case "${expected}" in
    ok|wrong-result|no-platform|no-device|context-failed|queue-failed) ;;
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

# shellcheck disable=SC2086
"${compiler}" -O2 -o "${workdir}/verify" scripts/verify-gemm.c \
    ${CLBLAST_CPPFLAGS:-} ${OPENCL_CPPFLAGS:-} \
    ${CLBLAST_LIBS:-} ${OPENCL_LIBS:-} -lm \
    || fail "verify-gemm.c did not compile against the exported flags"

output="$("${workdir}/verify")"
status=$?

for key in max-abs-error verify-status; do
    printf '%s\n' "${output}" | grep -q "^${key}=" \
        || fail "missing key '${key}' in output:
${output}"
done

err="$(printf '%s\n' "${output}" | sed -n 's/^max-abs-error=//p')"
case "${err}" in
    ''|*[!0-9.eE+inaf-]*) fail "max-abs-error '${err}' is not numeric or nan" ;;
esac

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

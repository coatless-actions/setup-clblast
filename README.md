# Setup CLBlast

[![Test](https://github.com/coatless-actions/setup-clblast/actions/workflows/test.yml/badge.svg)](https://github.com/coatless-actions/setup-clblast/actions/workflows/test.yml)

Install [CLBlast](https://github.com/CNugteren/CLBlast) on GitHub-hosted runners and prove a GEMM on it produces correct numbers before the job continues.

Installing a BLAS library is one package-manager line on Linux. Getting a *correct* one is harder, and getting it wrong is quiet in a way a linker cannot catch. On macOS, Homebrew's `clblast` bottle links Apple's `OpenCL.framework` and segfaults when loaded alongside the Khronos ICD loader. On any platform, `CLBlastSgemm` can return success and leave the output buffer holding garbage when the device's runtime kernel compilation fails. This action builds against the loader you actually installed, then runs a 64x64 SGEMM and compares it element-by-element against a reference computed on the host — checking the numbers, not a status code, is the only way to catch that failure mode.

## Quickstart

    name: test
    on: [push, pull_request]

    jobs:
      test:
        runs-on: ${{ matrix.os }}
        strategy:
          matrix:
            os: [ubuntu-24.04, macos-latest, windows-2025]
        steps:
          - uses: actions/checkout@v7
          - uses: coatless-actions/setup-opencl@v1
          - uses: coatless-actions/setup-clblast@v1
          - run: |
              # Windows runners ship mingw `gcc` rather than `cc`.
              compiler=cc
              command -v cc >/dev/null 2>&1 || compiler=gcc
              "$compiler" -o demo demo.c $CLBLAST_CPPFLAGS $OPENCL_CPPFLAGS $CLBLAST_LIBS $OPENCL_LIBS
            shell: bash

`setup-clblast` composes with `coatless-actions/setup-opencl` and **must run after it**. It fails closed — with an `::error::` naming the missing variable and telling you to add the `setup-opencl` step — when `OpenCL_ROOT` (or `OpenCL_LIBRARY`) is not already set in the job environment, rather than silently building against whatever loader it happens to find.

## Inputs

| Input | Description | Default |
|---|---|---|
| `version` | CLBlast version (git tag) to install. Empty means the tested default: the distribution package on Linux, `1.7.0` on macOS and Windows. Honored for a source build on any OS and for the Windows release asset; ignored, with a warning, for a Linux package install. CLBlast tags carry no `v` prefix — use `1.7.0`, not `v1.7.0`. A non-default value requires a paired `commit` whenever this action builds from source. | `''` |
| `commit` | Commit SHA the `version` tag must resolve to, for a source build. Required alongside a non-default `version` whenever this action builds from source (always on macOS; on Linux only when `source` resolves to `build`); ignored otherwise. Empty means the commit pinned for the default version. | `''` |
| `source` | Where CLBlast comes from: `auto`, `package`, or `build`. `auto` resolves to `package` on Linux and Windows and `build` on macOS. `package` is rejected on macOS (Homebrew's bottle links Apple's framework and segfaults alongside the Khronos loader) and `build` is rejected on Windows (upstream already publishes a binary of the newest release). | `auto` |
| `verify` | Compile and run a 64x64 SGEMM against the installed library and fail the job when the result is numerically wrong (`'true'` or `'false'`). Never fatal when no OpenCL device is present. | `true` |
| `cache` | Cache the macOS source-build tree and the Windows release archive (`'true'` or `'false'`). No-op on Linux: the apt package install has nothing to cache, and a Linux source build recompiles every run regardless of this input. | `true` |

`source`, `verify`, and `cache` are validated by hand, since the runner enforces neither input types nor allowed values. An **empty string** (for example `verify: ''`, which is what an absent key in a build matrix expands to) is rejected rather than falling back to the default — the action cannot distinguish "omitted" from "explicitly empty". Supplying `version` without `commit`, or `commit` without `version`, is an error whenever the resolved `source` is `build`; a package install only warns and ignores both.

## Outputs

| Output | Description |
|---|---|
| `clblast-root` | Root directory of the installed CLBlast. |
| `clblast-include-dir` | Directory containing `clblast_c.h`. |
| `clblast-library` | Full path to the CLBlast library. |
| `clblast-version` | CLBlast version actually installed. |
| `source-used` | `package` or `build`. |
| `verify-status` | `ok`, `wrong-result`, `no-platform`, `no-device`, `context-failed`, `queue-failed`, `buffer-failed`, a `gemm-status-N` code, or `skipped` when `verify` is `false`. |
| `max-abs-error` | Largest absolute difference between the device GEMM and a host reference. **Zero is the correct value, not a missing one** — do not test it for truthiness. `nan` whenever `verify-status` is anything other than `ok` or `wrong-result` (no comparable result was produced); empty when `verify` is `false` and the check was skipped. |

The action also exports `CLBLAST_CPPFLAGS`, `CLBLAST_LIBS`, and `CLBlast_ROOT` to the job environment, plus `CLBlast_DIR` when a usable `CLBlastConfig.cmake` is available, and `PKG_CONFIG_PATH` on Linux and macOS. On Windows, CLBlast's `bin` directory (containing `clblast.dll`) is prepended to `PATH`. A caller's own explicit setting of `CLBLAST_CPPFLAGS`, `CLBLAST_LIBS`, `CLBlast_ROOT`, or `CLBlast_DIR` always wins over the action's; `PKG_CONFIG_PATH` is prepended to rather than replaced, because it is a search path a caller legitimately accumulates entries in.

## Examples

### Pin a version for a source build

Ubuntu's apt package lags upstream (see below). To get a specific fixed version, pair `version` with the exact `commit` that tag resolves to:

    - uses: coatless-actions/setup-clblast@v1
      with:
        source: build
        version: '1.6.3'
        commit: '2a081972b20911ddf76a6b40df717c7d0c181268'

Find a tag's commit with `git ls-remote --tags https://github.com/CNugteren/CLBlast <version>`.

### Force a source build on Linux

    - uses: coatless-actions/setup-clblast@v1
      with:
        source: build

This is not cached — see `cache` in Inputs above — so it recompiles on every run.

### Install without running the numeric check

    - uses: coatless-actions/setup-clblast@v1
      with:
        verify: 'false'

### Branch on the measured error

    - uses: coatless-actions/setup-clblast@v1
      id: clblast
    - if: steps.clblast.outputs.verify-status == 'ok'
      run: ./run-blas-tests

## Supported runners

| Runner | Source | Version | Support |
|---|---|---|---|
| `ubuntu-24.04`, `ubuntu-24.04-arm` | apt `libclblast-dev` | 1.6.2 | Tested on every push and pull request |
| `macos-latest` | source build | 1.7.0 | Tested on every push and pull request |
| `windows-2025`, `windows-2022` | upstream release archive | 1.7.0 | Tested on every push and pull request |
| `ubuntu-26.04`, `ubuntu-26.04-arm` | apt `libclblast-dev` | 1.6.3 | Tested nightly, best effort |
| `ubuntu-22.04` | apt `libclblast-dev` | 1.5.2 | Tested nightly — **currently failing** |
| `macos-15-intel` | source build | 1.7.0 | Tested nightly, best effort |
| `ubuntu-latest`, `macos-latest`, `windows-latest` (floating labels) | whatever `auto` resolves to on that image | varies | Tested nightly, best effort. These labels move without notice |
| `windows-11-arm` | — | — | Not supported. Upstream publishes no Windows ARM64 build, and `setup-opencl` already rejects the platform |

`ubuntu-22.04`'s CLBlast 1.5.2 is not verified working: the nightly job currently fails there because that image's PoCL runtime cannot build the GEMM kernel (`clBuildProgram` reports `unknown target CPU 'generic'`, and the check reports `verify-status=gemm-status--11`). Do not treat that row as passing.

`source: package` is rejected on macOS and `source: build` is rejected on Windows. Both are deliberate: Homebrew's macOS bottle is unusable with the Khronos loader, and upstream already ships a Windows binary of the newest release.

## Notes on each platform

### Ubuntu 24.04 ships CLBlast 1.6.2

Upstream fixed a GEMM correctness bug in 1.6.3: "Fixed a bug in the GEMMK=1 kernel (with 2D register tiling) when MWG!=NWG." The action installs 1.6.2 on `ubuntu-24.04` anyway and emits a `::warning::` naming the fix.

That is a considered decision, not an oversight. The affected code path is only reachable on tuning-database entries with `GEMMK=1` and `MWG != NWG`. Every CPU device a GitHub-hosted runner offers falls back to entries with `GEMMK=0`, which is the unaffected kernel — so the bug cannot execute there, and the action's own GEMM check would not detect it either way. Use `source: build` with a paired `version`/`commit` (see Examples above) to get 1.6.3 or newer if your workload needs the fix, such as on a self-hosted GPU runner.

### macOS builds from source, and must

Homebrew's `clblast` bottle links `/System/Library/Frameworks/OpenCL.framework`. Loading that bottle alongside the Khronos `opencl-icd-loader` that `setup-opencl` installs produces a SIGSEGV. `source: package` on macOS is therefore an error rather than a fallback.

If a Homebrew `clblast` keg is present on the runner for unrelated reasons, this action emits a `::warning::`: build systems that probe Homebrew prefixes directly may find it instead of the library this action installed.

The build takes roughly 30 to 60 seconds cold on a hosted runner, and around 10 seconds when the tree is restored from cache — which it is by default.

### Windows verifies its download

Every Windows archive is checked against a pinned SHA-256 digest before extraction. CLBlast 1.7.0's digest comes from the GitHub Releases API's own `digest` field; older versions this action supports (currently 1.6.3) are verified against digests computed out of band and hardcoded in `scripts/install-windows.ps1`. A version with neither is **refused rather than installed unverified** — there is no fallback that skips the check.

Windows on ARM64 has no CLBlast archive upstream and is rejected outright with an actionable `::error::`.

### CMake consumers

CLBlast ships **no** `CLBlastConfigVersion.cmake` in any channel, so `find_package(CLBlast 1.7.0 REQUIRED)` fails everywhere. Use the version-less form, and note that the imported target is lowercase `clblast`, not `CLBlast::CLBlast`:

    find_package(CLBlast REQUIRED)
    target_link_libraries(consumer PRIVATE clblast)

On Windows, upstream's shipped `CLBlastConfig.cmake` bakes the build machine's vcpkg tree into its interface properties (`C:/vcpkg/packages/opencl_x64-windows/...`), paths that do not exist on a runner. This action rewrites those two lines to point at the loader `setup-opencl` installed. If the rewrite cannot be verified safe, `CLBlast_DIR` is not exported and the CMake config itself is replaced with a stub that fails loudly at configure time, rather than leaving a broken import target silently reachable through `CLBlast_ROOT`. A `::warning::` names the version; use `CLBLAST_CPPFLAGS` and `CLBLAST_LIBS` instead in that case.

## Requirements

- **Linux** needs `apt-get` and a C compiler (`cc`). `source: build` additionally needs `cmake` and `git`, which the action installs on that branch.
- **macOS** needs a C compiler (the Xcode Command Line Tools), `cmake`, and `git` — all preinstalled on every `macos-*` image.
- **Windows** needs `gcc` and 7-Zip, both preinstalled on `windows-2022` and `windows-2025`.

A C compiler and `apt-get` are preinstalled on every GitHub-hosted `ubuntu-*` image, but neither is guaranteed inside a `container:` job. Missing either fails the job with an `::error::` and remediation, not a bare `command not found`.

## Versioning

Pin the action by major version (`@v1`) for painless upgrades, by full tag (`@v1.0.0`) for strict reproducibility, or by SHA for the strictest pin.

## License

AGPL-3.0. See `LICENSE`.

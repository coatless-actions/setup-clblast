# Security Policy

## Why this matters here

This action's supply chain is platform-specific, and it is a different
shape from the sibling `setup-opencl` action's: this action does not touch
the Windows registry and does not install a vendor ICD loader entry -- that
remains `setup-opencl`'s job. What this action actually does is build or
install the CLBlast BLAS library and report where the result landed:

- **macOS**: builds CLBlast from source. The build checks out CLBlast at a
  commit SHA pinned to the resolved version and compiles it locally with
  CMake. No archive is downloaded on this path, so there is no digest to
  verify -- the pinned commit SHA is the integrity guarantee, with `git`
  itself as the transport.
- **Linux**: installs the `libclblast-dev` distribution package via `apt`.
  Integrity here comes from `apt`'s own repository signing, not from an
  independent check performed by this action.
- **Windows**: downloads a prebuilt CLBlast `.7z` release archive from
  GitHub Releases and extracts it with 7-Zip. This is the one path where
  this action fetches and must independently verify a third-party binary
  archive.

Every such archive is verified against a SHA-256 digest before extraction,
fail-closed -- a download with nothing to verify against is refused rather
than installed unverified, the same guarantee `setup-opencl` gives its own
downloads. `scripts/install-windows.ps1` resolves the expected digest in
this order: (1) a hand-maintained `$KnownDigests` table in that script,
seeded with digests computed out of band for versions the GitHub Releases
API predates; (2) the `digest` field the GitHub API reports for newer
releases; (3) failure. If neither source has a digest for the requested
version, the action stops with an `::error::` before downloading anything --
there is no path that installs an archive it could not verify. The
`.github/workflows/update-clblast.yml` workflow that bumps the pinned
default version to a new upstream release enforces the same rule: it
refuses to open a pull request for a release whose Windows asset has no
resolvable digest, rather than proposing a bump that the Windows leg of
`Test` cannot pass.

The action also exports the resolved install location (include/library
paths and, on Windows, the DLL directory) into job outputs and, on
Windows, `PATH`, so a workflow can compile and link against CLBlast
without re-deriving those paths itself.

## Supported versions

Security fixes are made to the latest tagged major version (`v1`) only. A
workflow pinned to `@v1` picks up a fix on its next run; a workflow pinned to
a specific `@v1.x.y` tag or commit SHA needs to be re-pinned manually.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Report it privately by emailing james.balamuta@gmail.com with a description
of the issue and, if possible, steps to reproduce it. Expect an
acknowledgment within a few days.

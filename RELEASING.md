# Local release process

Release work in this repository is preparation only. No command in `scripts/`
tags a commit, changes a Git remote, pushes, uploads, publishes, or submits to
opam. Publication remains a separate owner-authorized milestone.

## Candidate versioning

Use an opam-compatible semantic version such as `0.1.0~rc1`. The project is
pre-1.0 until the compatibility boundary in `COMPATIBILITY.md` has been reviewed
and every maturity-gate condition in `DESIGN_SPEC.md` has been met.

## Build a local candidate

From the repository root:

```sh
scripts/check-local.sh
scripts/check-sanitizers.sh
scripts/make-local-release.sh 0.1.0~rc1
scripts/verify-local-release.sh 0.1.0~rc1
```

The candidate is written beneath:

```text
_build/local-release/owebview-0.1.0~rc1/
  owebview-0.1.0~rc1.tar.gz
  owebview-0.1.0~rc1.tar.gz.sha256
  MANIFEST.txt
  opam-repository/packages/owebview/owebview.0.1.0~rc1/opam
```

The local opam file points to the absolute local archive and is suitable for
local linting/testing only. A future public release must replace that URL with
the reviewed public archive URL while preserving the verified checksum.

The source archive includes tracked and intentional untracked files, but
excludes ignored build output and `.git`. Its manifest records the Git commit,
whether the worktree was dirty, tool versions, host, and archive checksum.
Set `OWEBVIEW_REQUIRE_CLEAN=1` to reject a dirty source tree.

## Candidate review

A candidate is not ready even locally unless:

- `CHANGES.md` accurately describes it;
- public `.mli` documentation and generated odoc build cleanly;
- `COMPATIBILITY.md`, `MIGRATION.md`, `SECURITY.md`, and platform status are
  current;
- the package builds and installs from a fresh archive extraction;
- opam lint passes for both repository and candidate metadata;
- the current matrix cell passes and all unvalidated cells are explicitly
  recorded;
- native warning and applicable sanitizer checks pass;
- vendor provenance and license files are present;
- no secrets, private logs, generated credentials, or accidental local data are
  present in the archive.

## Reproducibility

The archive records source content, not Git timestamps, and uses normalized
ownership, order, and timestamps when the local tar implementation supports
them. Two candidates made from identical file contents and the same version
should have the same checksum. The verification script extracts into a new
temporary directory, rebuilds, tests, builds documentation, lints, and stages a
package install without modifying the active opam switch.

## Publication gate

Completing Phase 9 does not authorize publication. A future publication phase
must choose the public package coordinates, audit history and artifacts, create
or select a writable remote, review hosted CI, publish a release candidate, and
only then consider an opam-repository submission.

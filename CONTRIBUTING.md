# Contributing to the local fork

This repository is intentionally local-only. Contributions are developed as
local branches and commits. Do not push branches or tags, open pull requests,
publish packages, upload artifacts, or enable hosted CI unless the owner
separately opens the publication gate in `DESIGN_SPEC.md`.

## Project direction

The project targets native desktop applications with:

- OCaml 5.3 or newer;
- Eio as the only asynchronous runtime;
- a js_of_ocaml frontend using JavaScript Promises;
- typed RPC and bounded realtime streaming;
- conservative desktop security and explicit platform capabilities.

Lwt support and OCaml 4 compatibility are out of scope. Application framework
features such as project scaffolding, a frontend bundler, and application-level
agent orchestration belong above this binding/runtime library.

## Local workflow

Create a focused local branch, keep unrelated working-tree changes intact, and
run the narrow tests while developing. Before a local integration merge run:

```sh
scripts/check-local.sh
```

The command runs formatting, builds, unit tests, graphical integration tests,
documentation, a release-profile build, opam lint, package installation, and
strict native warnings. Sanitizers are separate because of toolchain-specific
limitations:

```sh
scripts/check-sanitizers.sh
```

Use `scripts/check-matrix.sh list` to see every planned platform/compiler cell
and `scripts/check-matrix.sh current` to execute the current machine's cell.

## Change requirements

- Public API changes update `.mli` documentation, `COMPATIBILITY.md`, and when
  needed `MIGRATION.md`.
- Wire changes include protocol tests and describe negotiation behavior.
- Native callback or lifecycle changes include a regression test that stresses
  GC, close races, or Domains as applicable.
- Stream changes test count and byte limits, cancellation, replay, and a slow
  consumer.
- Durable-session changes test persistence-before-visibility and recovery in a
  second operating-system process.
- Platform-specific additions update both capability reporting and
  `PLATFORM_SUPPORT.md`.
- Security-sensitive changes update `SECURITY.md` and include a negative test.
- User-visible changes update `CHANGES.md`.

Format OCaml and Dune files with the pinned formatter:

```sh
dune fmt
```

Do not edit `owebview.opam` directly; edit `dune-project` or
`owebview.opam.template`, then regenerate it with Dune.

## Local release candidates and backups

`scripts/make-local-release.sh VERSION` creates an archive and local opam
overlay under `_build/local-release`; it never tags, pushes, or uploads.
`scripts/verify-local-release.sh VERSION` verifies that archive from a fresh
extraction.

Because there is no writable remote, use `scripts/backup-local.sh DESTINATION`
to create a Git bundle and an archive of untracked files on separate local
storage. Backups may contain private source and must not be uploaded without
explicit authorization.

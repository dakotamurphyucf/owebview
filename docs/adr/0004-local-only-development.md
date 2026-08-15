# ADR 0004: Keep the fork local until an explicit publication gate

- Status: Accepted
- Date: August 12, 2026

## Decision

Keep branches, commits, tags, candidate archives, validation output, and opam
metadata local. Treat the inherited `origin` as read-only. Do not create hosted
CI, push, publish, or submit packages until the owner separately authorizes a
publication phase.

## Consequences

Quality automation must run locally and platform claims must distinguish
prepared from actually validated cells. Local backups are required because no
writable remote protects the work. Completing technical release work does not
authorize distribution.

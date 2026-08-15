# ADR 0003: One versioned and bounded application transport

- Status: Accepted
- Date: August 12, 2026

## Decision

Use one private native JavaScript binding per window, require a version and
capability handshake, and multiplex typed RPC, events, streams, and durable
session control over it. Bound every queue, replay buffer, batch, retained
session set, and handler pool.

## Consequences

The bridge has one auditable origin check and protocol gate. Overload becomes a
typed error or subscriber detachment instead of unbounded memory growth or UI
thread blocking. Shared pure endpoint definitions compile both natively and
with js_of_ocaml.

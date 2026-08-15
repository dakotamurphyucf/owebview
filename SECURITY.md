# Security model

`owebview` embeds a privileged native application backend beside a browser UI.
The browser document must therefore be treated as untrusted until both its
top-level origin and protocol handshake have been verified.

This repository is local-only and has no public issue tracker for this fork.
Potential vulnerabilities should be recorded privately with the owner and must
not be uploaded or disclosed through the read-only upstream remote without an
explicit publication decision.

## Trust boundary

The default application path is:

```text
trusted packaged frontend
  -> tokenized 127.0.0.1 asset origin
  -> native origin check
  -> version/capability handshake
  -> one private typed transport
  -> bounded Eio handlers
```

Navigation policy and binding-origin checks are independent defenses. Allowing
a URL to display does not grant it native transport access. A transport request
is accepted only when the native WebView callback reports a trusted current
top-level URL and the frontend has completed a compatible handshake.

## Safe defaults

- Production assets require operating-system secure random bytes for the
  process-local URL token.
- Assets are served from IPv4 loopback and are not exposed on external network
  interfaces.
- `file://` is not used for the production application origin.
- Responses set explicit MIME types, content security policy, no-sniff,
  referrer, cache, and same-origin resource-policy headers.
- Directory paths are normalized and traversal outside the configured root is
  rejected.
- External HTTP(S) navigation is rejected or delegated to the operating system
  instead of inheriting native bridge privileges.
- Binding queues, worker concurrency, stream queues, replay storage, encoded
  batches, retained sessions, and per-window durable delivery are bounded.
- Release-facing protocol errors are sanitized; native backtraces are sent to
  the application error hook, not to the browser.
- Permission and download decisions default to denial unless the application
  installs an explicit policy.

## Application responsibilities

Applications must:

- keep production frontend code and assets trustworthy;
- disable debug/developer tools in release builds unless there is a deliberate
  operational need;
- use production asset mode outside local development;
- validate all endpoint payloads even though they came through a typed codec;
- authorize durable-session listing, attachment, commands, and cancellation
  when data belongs to a user, account, or tenant;
- avoid placing secrets in URLs, browser console messages, frontend errors, or
  durable event history;
- use stable command IDs and reconcile any command restored as `Admitted`
  before repeating an external side effect;
- apply least-privilege policies for external navigation, downloads,
  clipboard, filesystem dialogs, and future protected-resource permissions;
- define a retention policy for durable sessions and securely remove sensitive
  application data when required.

The loopback token is a defense-in-depth capability, not authentication for
multiple operating-system users or hostile local processes. Applications with
stronger local-adversary requirements should add authenticated messages or a
platform-specific private scheme and should encrypt sensitive persistence.

## Durable storage

Directory persistence uses temporary-file write, flush, `fsync`, atomic rename,
and directory synchronization. This protects snapshot consistency; it does not
encrypt data or make external effects transactional. The containing directory's
permissions, backups, disk encryption, retention, and deletion policy are the
application's responsibility.

## Native handles

Values returned by `Webview.get_window` and `Webview.get_native_handle` bypass
the portable abstraction. They are borrowed pointers, valid only while the
managed WebView is alive, and should be touched only on the UI thread. Incorrect
foreign code can invalidate all OCaml runtime safety guarantees.

## Security review checklist

Before any publication or application release:

1. Run `scripts/check-local.sh` and applicable sanitizer jobs.
2. Review every trusted origin and navigation exception.
3. Verify production mode, CSP, and debug settings.
4. Fuzz or negatively test changed codecs and path handling.
5. Review queue/byte/session limits against expected hostile input.
6. Review persisted data, filesystem permissions, retention, and backups.
7. Audit logs and release artifacts for secrets and private paths.
8. Review the vendored native diff and provenance.

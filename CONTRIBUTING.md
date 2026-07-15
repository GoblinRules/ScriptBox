# Contributing to ScriptBox

ScriptBox is intentionally a small, auditable, single-file launcher. Contributions are welcome when they preserve that simplicity.

## Catalog entries

- Give every item a unique, stable `Id`.
- Explain the outcome in `Description` and the concrete system effect in `Impact`.
- Set `RequiresAdmin` only when the commands truly need elevation.
- Set `NeedsBypass` only for a child process that cannot run under the normal policy.
- Set `RequiresConfirmation` for shutdown, restart, destructive actions, and remote code.
- Set `RunsRemoteCode` for every download-and-execute flow.
- Prefer HTTPS sources controlled by the upstream project.
- Never commit secrets, credentials, customer details, or private infrastructure addresses.

Run the parser and UI validation commands in the README before opening a pull request. Never test restart, shutdown, or third-party remote launchers on a machine where interruption or system changes would be unsafe.


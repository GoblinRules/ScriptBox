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

## Publishing runtime changes

The launcher is downloaded from `main`, while action scripts are downloaded from the immutable tag matching `$script:Version` in `ScriptBox.ps1`. Therefore, every user-visible or runtime change to `ScriptBox.ps1`, `scripts/**`, or `assets/**` must include a semantic version bump. Use a patch bump for fixes unless the change warrants a minor or major release.

After the change reaches `main`, the **Publish version tag** GitHub workflow creates the annotated `v<version>` tag automatically. It fails rather than moving or reusing an existing tag. Pull requests are also checked to ensure runtime changes include a new version.

Before considering a release complete, verify that the workflow succeeded and that both the `main` launcher and the version-tagged action scripts contain the intended change. Destructive action scripts must be validated by parsing or in a disposable test environment, never by executing them on a development machine.

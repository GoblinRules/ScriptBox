# Repository instructions

## Release invariant

`ScriptBox.ps1` is loaded from `main`, but its action scripts are loaded from the immutable tag matching `$script:Version`. A launcher or action-script change is not complete until both sources resolve to the same commit.

For every user-visible or runtime change to `ScriptBox.ps1`, `scripts/**`, or `assets/**`:

1. Increment `$script:Version` in `ScriptBox.ps1` using semantic versioning. Use a patch bump for fixes unless the requested change warrants a minor or major bump.
2. Parse `ScriptBox.ps1` and every `scripts/*.ps1` file without executing them. Destructive scripts must never be used for local validation.
3. Commit the runtime change and version bump together.
4. Publish the commit to `main`. The `Publish version tag` GitHub workflow creates the matching annotated `v<version>` tag.
5. Wait for that workflow and verify all three references resolve correctly:
   - `main/ScriptBox.ps1` declares the new version.
   - `v<version>/scripts` contains the matching action scripts.
   - `scriptbox.revhooks.cc` launches the new displayed version.

Never reuse, move, or overwrite an existing version tag. Documentation-only changes do not require a version bump. Keep `temp/` and other local artifacts out of commits.

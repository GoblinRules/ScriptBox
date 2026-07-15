# ScriptBox

ScriptBox is a portable Windows PowerShell launcher with a friendly, category-based UI. Every script has an information view, clear privilege and policy badges, confirmation for higher-risk actions, automatic UAC elevation when required, and live terminal output.

![ScriptBox icon](assets/icon.png)

## Run it

Open Windows PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/GoblinRules/ScriptBox/main/ScriptBox.ps1 | iex
```

ScriptBox does not install itself. It keeps its icon and output bridge in a uniquely named Windows temporary folder and removes that folder when the app closes. Scripts launched from the catalog may make their own documented system changes or install/open third-party tools.

> `irm | iex` executes code from the internet. Review [`ScriptBox.ps1`](ScriptBox.ps1) and the source URLs shown by each script before running it.

## Included sections

- **Power** — restart or shut down Windows with a visible countdown and confirmation.
- **Windows** — remove common Windows location policy blocks and restore the Geolocation Service.
- **Tools** — launch JetFuel, InvokeX, or Chris Titus Tech Windows Utility from their current remote source.
- **Diagnostics** — test either the viewer-side Tailscale path to a KVM or the KVM-site router, NAT, firewall, and UDP conditions.

Use the **i** button to inspect impact, elevation, execution-policy behavior, remote-code status, and the exact script. Use **RUN** to execute it. Scripts that need administrator rights trigger Windows UAC automatically. Only catalog entries marked as requiring a policy bypass receive `-ExecutionPolicy Bypass`, and only for their child PowerShell process.

## Add or edit a script

All entries live in the clearly marked `SCRIPT CATALOG` array in [`ScriptBox.ps1`](ScriptBox.ps1). Longer diagnostics are kept as standalone files in [`scripts`](scripts) so they are easy to review and edit. Add another `New-CatalogItem` block:

```powershell
New-CatalogItem `
    -Id 'my-script' `
    -Name 'My Script' `
    -Category 'Maintenance' `
    -Description 'Explains the result in one sentence.' `
    -Impact 'Describes exactly what changes.' `
    -RequiresAdmin $false `
    -NeedsBypass $false `
    -RequiresConfirmation $false `
    -RunsRemoteCode $false `
    -InputTitle '' `
    -InputMessage '' `
    -InputVariable '' `
    -Accent '#22D3EE' `
    -Script {
        Write-Host 'Hello from ScriptBox'
    }
```

Categories and counts are generated automatically. Set the three input fields when a script needs one text value before launch; ScriptBox shows a matching themed prompt and passes the value only to that run. Delete an entry to remove it; edit its fields to change the UI or behavior.

## Design and safety notes

- Windows PowerShell 5.1 and WPF are already included with supported desktop versions of Windows.
- PowerShell 7 launches a short Windows PowerShell STA handoff because WPF requires an STA thread; the handoff itself does not use a policy bypass.
- Script output is streamed from a temporary UTF-8 log and removed after completion or app shutdown.
- Restart and shutdown can be cancelled during their countdown with `shutdown /a`.
- Remote launchers can change independently. Their entries are marked clearly and require confirmation.
- The KVM diagnostics make no network, firewall, Tailscale, or router changes. By default, each saves a timestamped text report to the current user's Downloads folder.
- Do not add passwords, tokens, private URLs, or other secrets to this public repository.

## Validate a change

Parse the script without running it:

```powershell
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    "$PWD\ScriptBox.ps1",
    [ref]$null,
    [ref]$errors
)
$errors
```

Validate both standalone KVM diagnostics without running network tests:

```powershell
powershell.exe -NoProfile -File .\scripts\KvmClientTailscaleDiagnostics.ps1 -ValidationOnly -NonInteractive
powershell.exe -NoProfile -File .\scripts\KvmSiteNetworkDiagnostics.ps1 -ValidationOnly -NonInteractive
```

Load and validate the UI without showing the window or running a catalog item:

```powershell
$env:SCRIPTBOX_TEST_MODE = '1'
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\ScriptBox.ps1
Remove-Item Env:\SCRIPTBOX_TEST_MODE
```

## License

[MIT](LICENSE)

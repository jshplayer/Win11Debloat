<!-- Win11Debloat - Minimal runtime documentation -->
# Win11Debloat

This repository contains one local PowerShell runtime and one adjacent configuration file:

- `Win11Debloat.ps1` validates and applies a named registry preset.
- `Win11Debloat.json` contains every allowed operation in plain JSON.

The runtime preserves all 90 registry-backed presets from the original repository. `Defaults` is the default preset and applies the original default registry-backed selection while retaining the Microsoft Copilot app. Every registry write, value deletion, and key deletion is declared in `Win11Debloat.json`.

The original non-registry features are intentionally excluded: app removal, restore-point creation, Store suggestion database changes, Widgets/Copilot package removal, forced Edge removal, optional Windows features, scheduled-task changes, and Start-menu binary changes.

The runtime never downloads code, invokes an expression, removes applications, or loads files outside the chosen configuration path. When approved pending changes require machine-wide registry access, it relaunches itself through Windows UAC with the selected preset and configuration path.

At startup the runtime compares the selected preset with the current registry state and shows each change category's intended, already-matched, and pending operation counts. It clears the screen for interactive runs, checks elevation only for pending machine-wide changes, and asks once for approval before applying them. Inaccessible or failed registry operations are skipped and reported together after the remaining operations complete. Interactive runs pause for Enter before exit; `-WhatIf` and `-Approve` remain non-interactive. Use `-Approve` only for deliberate unattended runs.

Run a preview first:

```powershell
.\Win11Debloat.ps1 -WhatIf
```

List or apply presets:

```powershell
.\Win11Debloat.ps1 -ListPresets
.\Win11Debloat.ps1 -Preset DisableTelemetry
.\Win11Debloat.ps1 -Preset DisableTelemetry -Approve
```

The script requests elevation only after approval when the selected pending operations require `HKLM`, `HKU`, or `HKCR`. Review and edit `Win11Debloat.json` before applying any preset.
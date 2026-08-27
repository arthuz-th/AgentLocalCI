# Installing and uninstalling

## Install from source

```powershell
pwsh -NoProfile -File .\install.ps1
agentlocalci doctor --build-image
```

The installer requires PowerShell 7.4+, validates a narrow non-reparse install root, computes a controller identity from all module files plus the CLI entry point, verifies existing content before reusing an identity, copies the controller into `%LOCALAPPDATA%\AgentLocalCI\controller\<identity>`, writes user-local shims, preserves an existing policy, and optionally adds only the AgentLocalCI `bin` directory to the user PATH. A modified existing identity fails closed until an explicit `-Force` repair replaces it with source-matching content.

Use `-NoPath` to leave PATH unchanged or `-InstallRoot` for an isolated test installation.

## Upgrade

Run the installer from the new source tree. Controllers are side-by-side by identity; `current.json` and the shims select the newest installed controller. Existing policy and run reports remain under the install root.

## Uninstall

```powershell
agentlocalci uninstall
```

or:

```powershell
pwsh -NoProfile -File .\install.ps1 -Uninstall
```

Uninstall removes the AgentLocalCI `bin` entry from user PATH and preserves the installation in a timestamped backup instead of permanently deleting reports. When invoked through `agentlocalci uninstall`, Windows must keep the currently executing command shims available until the batch process exits, so the CLI leaves a small `bin` plus `UNINSTALLED.txt` tombstone at the old root and moves all active controller, policy, runtime, and manifest state into the backup. Reinstalling over the tombstone is supported. After closing shells that still reference the old command, the tombstone directory can be deleted manually. Running `install.ps1 -Uninstall` from a separate source tree can move the complete installation root directly.

The CLI and installer uninstall paths require a valid AgentLocalCI ownership manifest and refuse unrelated directories or reparse points. Do not point `--home` or `-InstallRoot` at a broad or unrelated directory.

# Installing, upgrading, and uninstalling

## Prerequisites

- PowerShell 7.4+
- Git
- a running Linux Docker engine
- default policy minimum of 20 GiB free disk

On macOS:

```bash
brew install powershell
brew install --cask docker
```

## Install from source

```powershell
pwsh -NoProfile -File ./install.ps1
```

Default roots:

| Host | Root |
|---|---|
| Windows | `%LOCALAPPDATA%\AgentLocalCI` |
| macOS | `~/Library/Application Support/AgentLocalCI` |
| Linux | `$XDG_STATE_HOME/agentlocalci` or `~/.local/state/agentlocalci` |

The installer validates a narrow non-symlink/reparse root, computes an identity from all controller files plus the CLI entry point, verifies existing content before reusing an identity, installs controllers side-by-side, preserves policy and reports, and writes Windows plus portable shell shims.

On Windows, PATH is updated through the user environment. On macOS/Linux, the installer manages only the block between these markers in `~/.zprofile` or `~/.profile`:

```text
# >>> AgentLocalCI PATH >>>
# <<< AgentLocalCI PATH <<<
```

Use `-NoPath` to leave PATH/profile unchanged. Use `-InstallRoot` for an isolated location. A modified existing controller identity fails closed until `-Force` restores source-matching content.

## Guided first run

```powershell
agentlocalci quickstart --commit --open
```

Without `--commit`, quickstart creates the configuration and stops so it can be reviewed. `--commit` is allowed only when the new pipeline is the sole working-tree change.

## Upgrade

Pull or check out the new release and rerun `install.ps1`. The manifest and shims select the new controller identity. Existing policy and run reports remain.

## Uninstall

```powershell
agentlocalci uninstall
```

or from a separate source checkout:

```powershell
pwsh -NoProfile -File ./install.ps1 -Uninstall
```

Uninstall requires a valid AgentLocalCI ownership manifest, removes only the managed PATH entry/block, and moves the installation to a timestamped recoverable backup. Windows CLI uninstall leaves a minimal command-shim tombstone until the invoking batch process exits; reinstall over that tombstone is supported. Unix CLI uninstall can move the full root directly.

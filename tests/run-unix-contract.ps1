[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
if ($IsWindows) { throw "run-unix-contract.ps1 must run on a Unix PowerShell host" }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

Write-Output "=== UNIX UNIT AND BEGINNER CONTRACT ==="
& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $repoRoot "tests/run-unit.ps1")
if ($LASTEXITCODE -ne 0) { throw "Unix unit contract failed with exit $LASTEXITCODE" }

Write-Output "=== UNIX INSTALLER LIFECYCLE ==="
& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $repoRoot "tests/run-installer-integration.ps1")
if ($LASTEXITCODE -ne 0) { throw "Unix installer lifecycle failed with exit $LASTEXITCODE" }

Write-Output "=== UNIX MANAGED PATH PROFILE ==="
& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $repoRoot "tests/run-unix-profile-integration.ps1")
if ($LASTEXITCODE -ne 0) { throw "Unix managed PATH profile contract failed with exit $LASTEXITCODE" }

Write-Output "PASS Unix controller, beginner UX, hook, report, installer, and managed PATH contracts"

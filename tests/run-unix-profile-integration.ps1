[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
if ($IsWindows) { throw "run-unix-profile-integration.ps1 requires macOS or Linux" }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$installer = Join-Path $repoRoot "install.ps1"
$userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
$profile = if ($IsMacOS) { Join-Path $userHome ".zprofile" } else { Join-Path $userHome ".profile" }
$originalExists = Test-Path -LiteralPath $profile -PathType Leaf
$original = if ($originalExists) { [IO.File]::ReadAllText($profile, [Text.Encoding]::UTF8) } else { "" }
$sentinel = "# unrelated-profile-sentinel-$([Guid]::NewGuid().ToString('N'))"
$installRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-profile-install-" + [Guid]::NewGuid().ToString("N") + "/AgentLocalCI")

try {
    [IO.File]::WriteAllText($profile, $original + $(if ($original.EndsWith("`n") -or $original.Length -eq 0) { "" } else { "`n" }) + "$sentinel`n", [Text.UTF8Encoding]::new($false))
    & pwsh -NoLogo -NoProfile -NonInteractive -File $installer -InstallRoot $installRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unix managed-PATH install failed" }
    $text = [IO.File]::ReadAllText($profile, [Text.Encoding]::UTF8)
    if ([Regex]::Matches($text, '(?m)^# >>> AgentLocalCI PATH >>>$').Count -ne 1) { throw "managed PATH start marker count is not one" }
    if ([Regex]::Matches($text, '(?m)^# <<< AgentLocalCI PATH <<<$').Count -ne 1) { throw "managed PATH end marker count is not one" }
    if (-not $text.Contains($sentinel, [StringComparison]::Ordinal) -or -not $text.Contains((Join-Path $installRoot "bin"), [StringComparison]::Ordinal)) { throw "installer removed foreign profile content or omitted bin path" }

    & pwsh -NoLogo -NoProfile -NonInteractive -File $installer -InstallRoot $installRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "repeated Unix managed-PATH install failed" }
    $text = [IO.File]::ReadAllText($profile, [Text.Encoding]::UTF8)
    if ([Regex]::Matches($text, '(?m)^# >>> AgentLocalCI PATH >>>$').Count -ne 1) { throw "repeated install duplicated the managed PATH block" }

    & pwsh -NoLogo -NoProfile -NonInteractive -File $installer -InstallRoot $installRoot -Uninstall | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unix managed-PATH uninstall failed" }
    $text = [IO.File]::ReadAllText($profile, [Text.Encoding]::UTF8)
    if ($text -match 'AgentLocalCI PATH' -or -not $text.Contains($sentinel, [StringComparison]::Ordinal)) { throw "uninstall retained owned profile content or removed foreign content" }
    Write-Output "PASS Unix shell-profile PATH block is idempotent, owner-bounded, and removable"
}
finally {
    if ($originalExists) { [IO.File]::WriteAllText($profile, $original, [Text.UTF8Encoding]::new($false)) }
    elseif (Test-Path -LiteralPath $profile) { Remove-Item -LiteralPath $profile -Force }
    if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
    $parent = Split-Path -Parent $installRoot
    foreach ($backup in @(Get-ChildItem -LiteralPath $parent -Directory -Filter ((Split-Path -Leaf $installRoot) + '.uninstalled-*') -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $backup.FullName -Recurse -Force }
}

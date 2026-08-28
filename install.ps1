[CmdletBinding()]
param(
    [string]$InstallRoot,
    [switch]$NoPath,
    [switch]$Force,
    [switch]$Uninstall
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion -lt [Version]"7.4") { throw "AgentLocalCI requires PowerShell 7.4 or newer" }

function Get-HostPlatform {
    if ($IsWindows) { return "windows" }
    if ($IsMacOS) { return "macos" }
    if ($IsLinux) { return "linux" }
    throw "AgentLocalCI supports Windows, macOS, and Linux hosts"
}

function Get-PathComparison {
    if ((Get-HostPlatform) -ceq "windows") { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Get-PathComparer {
    if ((Get-HostPlatform) -ceq "windows") { return [StringComparer]::OrdinalIgnoreCase }
    return [StringComparer]::Ordinal
}

function Test-PathEquals([string]$Left, [string]$Right) {
    return $Left.Equals($Right, (Get-PathComparison))
}

function Get-UserHome {
    $value = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable("HOME", "Process") }
    if ([string]::IsNullOrWhiteSpace($value)) { throw "The current user home directory is unavailable" }
    return [IO.Path]::GetFullPath($value)
}

function Get-DefaultInstallRoot {
    switch (Get-HostPlatform) {
        "windows" {
            $root = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            if ([string]::IsNullOrWhiteSpace($root)) { throw "LOCALAPPDATA is unavailable" }
            return Join-Path $root "AgentLocalCI"
        }
        "macos" { return Join-Path (Get-UserHome) "Library/Application Support/AgentLocalCI" }
        "linux" {
            $root = [Environment]::GetEnvironmentVariable("XDG_STATE_HOME", "Process")
            if ([string]::IsNullOrWhiteSpace($root)) { $root = Join-Path (Get-UserHome) ".local/state" }
            return Join-Path $root "agentlocalci"
        }
    }
}

function Get-DefaultProfilePath {
    switch (Get-HostPlatform) {
        "macos" { return Join-Path (Get-UserHome) ".zprofile" }
        "linux" { return Join-Path (Get-UserHome) ".profile" }
        default { return "" }
    }
}

function Assert-NoReparseAncestor([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($cursor)
    while ($true) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "AgentLocalCI refuses reparse-point or symbolic-link install paths: $cursor" }
        }
        if (Test-PathEquals $cursor $root) { break }
        $parentInfo = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parentInfo) { throw "Could not prove the install path ancestry" }
        $cursor = [IO.Path]::GetFullPath($parentInfo.FullName)
    }
}

function Get-SafeRoot([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if (Test-PathEquals $full $root) { throw "AgentLocalCI refuses a filesystem root: $full" }
    $relative = $full.Substring($root.Length).Trim([char[]]@('\', '/'))
    $segments = @($relative -split '[\\/]' | Where-Object { $_ })
    if ($segments.Count -lt 2) { throw "AgentLocalCI refuses a broad install root: $full" }
    Assert-NoReparseAncestor $full
    return $full.TrimEnd([char[]]@('\', '/'))
}

function Get-FileInventory([string]$BasePath, [string]$Prefix = "") {
    $base = [IO.Path]::GetFullPath($BasePath).TrimEnd([char[]]@('\', '/'))
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "Inventory root is missing: $base" }
    $baseItem = Get-Item -LiteralPath $base -Force
    if (($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "AgentLocalCI refuses a reparse-point inventory root" }
    $inventory = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($item in @(Get-ChildItem -LiteralPath $base -Force -Recurse | Sort-Object FullName)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "AgentLocalCI refuses reparse points in installer source or controller content" }
        if ($item.PSIsContainer) { continue }
        $relative = [IO.Path]::GetRelativePath($base, $item.FullName).Replace([char]92, '/')
        $key = if ([string]::IsNullOrWhiteSpace($Prefix)) { $relative } else { "$($Prefix.TrimEnd('/'))/$relative" }
        if ($inventory.ContainsKey($key)) { throw "Duplicate controller inventory path: $key" }
        $inventory.Add($key, (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    return ,$inventory
}

function Assert-FileInventoriesEqual([Collections.Generic.SortedDictionary[string,string]]$Expected, [Collections.Generic.SortedDictionary[string,string]]$Actual) {
    if ($Expected.Count -ne $Actual.Count) { throw "Existing controller identity is incomplete or contains extra files; rerun with -Force" }
    foreach ($entry in $Expected.GetEnumerator()) {
        if (-not $Actual.ContainsKey($entry.Key) -or $Actual[$entry.Key] -cne $entry.Value) { throw "Existing controller identity is corrupt or modified; rerun with -Force" }
    }
}

function ConvertTo-ShellSingleQuoted([string]$Value) {
    $single = [string][char]39
    $double = [string][char]34
    $embeddedSingle = $single + $double + $single + $double + $single
    return $single + $Value.Replace($single, $embeddedSingle) + $single
}

function Remove-ManagedShellPath([string]$ProfilePath) {
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) { return $false }
    $text = [IO.File]::ReadAllText($ProfilePath, [Text.Encoding]::UTF8)
    $pattern = '(?ms)^# >>> AgentLocalCI PATH >>>\r?\n.*?^# <<< AgentLocalCI PATH <<<\r?\n?'
    $updated = [Regex]::Replace($text, $pattern, "")
    if ($updated -ceq $text) { return $false }
    [IO.File]::WriteAllText($ProfilePath, $updated, [Text.UTF8Encoding]::new($false))
    return $true
}

function Update-ManagedShellPath([string]$Directory, [string]$ProfilePath, [bool]$Add) {
    if ([string]::IsNullOrWhiteSpace($ProfilePath)) { return }
    $parent = Split-Path -Parent $ProfilePath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [void](Remove-ManagedShellPath $ProfilePath)
    if (-not $Add) { return }
    $existing = if (Test-Path -LiteralPath $ProfilePath -PathType Leaf) { [IO.File]::ReadAllText($ProfilePath, [Text.Encoding]::UTF8) } else { "" }
    if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n", [StringComparison]::Ordinal)) { $existing += "`n" }
    $block = "# >>> AgentLocalCI PATH >>>`nexport PATH=$(ConvertTo-ShellSingleQuoted $Directory):`"`$PATH`"`n# <<< AgentLocalCI PATH <<<`n"
    [IO.File]::WriteAllText($ProfilePath, $existing + $block, [Text.UTF8Encoding]::new($false))
}

function Update-UserPath([string]$Directory, [bool]$Add, [string]$ProfilePath) {
    $normalized = [IO.Path]::GetFullPath($Directory).TrimEnd([char[]]@('\', '/'))
    if ((Get-HostPlatform) -ceq "windows") {
        $current = [Environment]::GetEnvironmentVariable("Path", "User")
        $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $kept = @($parts | Where-Object {
            try { -not (Test-PathEquals ([IO.Path]::GetFullPath($_).TrimEnd([char[]]@('\', '/'))) $normalized) }
            catch { $true }
        })
        if ($Add) { $kept += $normalized }
        [Environment]::SetEnvironmentVariable("Path", ($kept -join ';'), "User")
        if ($Add -and -not (($env:Path -split ';') | Where-Object { try { Test-PathEquals ([IO.Path]::GetFullPath($_).TrimEnd([char[]]@('\', '/'))) $normalized } catch { $false } })) { $env:Path = "$normalized;$env:Path" }
        return
    }
    Update-ManagedShellPath $normalized $ProfilePath $Add
}

function Set-UnixExecutable([string]$Path) {
    if ((Get-HostPlatform) -ceq "windows") { return }
    [IO.File]::SetUnixFileMode($Path,
        [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor
        [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor
        [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute)
}

$platform = Get-HostPlatform
$root = Get-SafeRoot $(if ([string]::IsNullOrWhiteSpace($InstallRoot)) { Get-DefaultInstallRoot } else { $InstallRoot })
$binRoot = Join-Path $root "bin"
$manifestPath = Join-Path $root "current.json"
$existingManifest = $null
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try { $existingManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20 }
    catch { $existingManifest = $null }
}

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        [pscustomobject]@{ Uninstalled = $false; Reason = "not installed"; InstallRoot = $root }
        exit 0
    }
    if ($null -eq $existingManifest) { throw "Refusing to uninstall a directory without a valid AgentLocalCI ownership manifest" }
    if (
        [string]$existingManifest.product -cne "AgentLocalCI" -or
        [int]$existingManifest.schema_version -ne 1 -or
        [string]$existingManifest.identity -cnotmatch '^[0-9a-f]{20}$'
    ) { throw "Refusing to uninstall a directory not proven to be owned by AgentLocalCI" }
    $controllerRoot = [IO.Path]::GetFullPath([string]$existingManifest.controller_root).TrimEnd([char[]]@('\', '/'))
    $ownedPrefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $controllerRoot.StartsWith($ownedPrefix, (Get-PathComparison))) { throw "Refusing to uninstall because the controller escaped the AgentLocalCI root" }
    $managed = if ($null -ne $existingManifest.PSObject.Properties["path_managed"]) { [bool]$existingManifest.path_managed } else { $true }
    $profilePath = if ($null -ne $existingManifest.PSObject.Properties["path_profile"]) { [string]$existingManifest.path_profile } else { Get-DefaultProfilePath }
    if ($managed) { Update-UserPath $binRoot $false $profilePath }
    $backup = "$root.uninstalled-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    Move-Item -LiteralPath $root -Destination $backup
    [pscustomobject]@{ Uninstalled = $true; Backup = $backup; ReportsPreserved = $true; PathUpdated = $managed; RestartShell = $managed }
    exit 0
}

$sourceModule = Join-Path $PSScriptRoot "src/AgentLocalCI"
$sourceCli = Join-Path $PSScriptRoot "bin/agentlocalci.ps1"
$defaultPolicy = Join-Path $PSScriptRoot "config/default-policy.yml"
foreach ($required in @($sourceModule, $sourceCli, $defaultPolicy)) { if (-not (Test-Path -LiteralPath $required)) { throw "Installer source is incomplete: $required" } }
$product = Get-Content -LiteralPath (Join-Path $sourceModule "product.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$sourceInventory = Get-FileInventory $sourceModule "src/AgentLocalCI"
$sourceCliItem = Get-Item -LiteralPath $sourceCli -Force
if (($sourceCliItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "AgentLocalCI refuses a reparse-point CLI source" }
$sourceInventory.Add("bin/agentlocalci.ps1", (Get-FileHash -LiteralPath $sourceCli -Algorithm SHA256).Hash.ToLowerInvariant())
$parts = [Collections.Generic.List[string]]::new()
$parts.Add("AgentLocalCI/$($product.version)")
foreach ($entry in $sourceInventory.GetEnumerator()) { $parts.Add("$($entry.Key):$($entry.Value)") }
$algorithm = [Security.Cryptography.SHA256]::Create()
try { $identity = (($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($parts -join "`n")) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,20) }
finally { $algorithm.Dispose() }

[IO.Directory]::CreateDirectory($root) | Out-Null
[IO.Directory]::CreateDirectory($binRoot) | Out-Null
$controllerRoot = Join-Path (Join-Path $root "controller") $identity
if (Test-Path -LiteralPath $controllerRoot) {
    $controllerItem = Get-Item -LiteralPath $controllerRoot -Force
    if (($controllerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Existing controller identity is a reparse point; refusing mutation" }
    if (-not $Force) { Assert-FileInventoriesEqual $sourceInventory (Get-FileInventory $controllerRoot) }
    else {
        Remove-Item -LiteralPath $controllerRoot -Recurse -Force
        if (Test-Path -LiteralPath $controllerRoot) { throw "Forced repair could not prove removal of the previous controller identity" }
    }
}
if (-not (Test-Path -LiteralPath $controllerRoot)) {
    [IO.Directory]::CreateDirectory((Join-Path $controllerRoot "src")) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $controllerRoot "bin")) | Out-Null
    Copy-Item -LiteralPath $sourceModule -Destination (Join-Path $controllerRoot "src/AgentLocalCI") -Recurse
    Copy-Item -LiteralPath $sourceCli -Destination (Join-Path $controllerRoot "bin/agentlocalci.ps1")
}
Assert-FileInventoriesEqual $sourceInventory (Get-FileInventory $controllerRoot)

$target = Join-Path $controllerRoot "bin/agentlocalci.ps1"
$shimPs1 = @"
`$target = '$($target.Replace("'", "''"))'
if (-not (Test-Path -LiteralPath `$target -PathType Leaf)) { [Console]::Error.WriteLine('AgentLocalCI controller is missing'); exit 3 }
& pwsh -NoLogo -NoProfile -NonInteractive -File `$target @args
exit `$LASTEXITCODE
"@
[IO.File]::WriteAllText((Join-Path $binRoot "agentlocalci.ps1"), $shimPs1, [Text.UTF8Encoding]::new($false))

if ($platform -ceq "windows") {
    $shimCmd = "@pwsh.exe -NoLogo -NoProfile -NonInteractive -File `"$target`" %* & call exit /b %%errorlevel%%`r`n"
    [IO.File]::WriteAllText((Join-Path $binRoot "agentlocalci.cmd"), $shimCmd, [Text.ASCIIEncoding]::new())
}

$unixTarget = ConvertTo-ShellSingleQuoted $target
$shimSh = "#!/bin/sh`nexec pwsh -NoLogo -NoProfile -NonInteractive -File $unixTarget `"`$@`"`n"
$unixShim = Join-Path $binRoot "agentlocalci"
[IO.File]::WriteAllText($unixShim, $shimSh, [Text.UTF8Encoding]::new($false))
Set-UnixExecutable $unixShim

$tombstone = Join-Path $root "UNINSTALLED.txt"
if (Test-Path -LiteralPath $tombstone -PathType Leaf) { Remove-Item -LiteralPath $tombstone -Force }
if (-not (Test-Path -LiteralPath (Join-Path $root "policy.yml"))) { Copy-Item -LiteralPath $defaultPolicy -Destination (Join-Path $root "policy.yml") }

$profilePath = Get-DefaultProfilePath
$previouslyManaged = $false
if ($null -ne $existingManifest -and $null -ne $existingManifest.PSObject.Properties["path_managed"]) { $previouslyManaged = [bool]$existingManifest.path_managed }
$pathManaged = -not $NoPath -or $previouslyManaged
if (-not $NoPath) { Update-UserPath $binRoot $true $profilePath }
$current = [ordered]@{
    product = "AgentLocalCI"
    schema_version = 1
    version = [string]$product.version
    identity = $identity
    controller_root = $controllerRoot
    bin_root = $binRoot
    host_platform = $platform
    path_managed = $pathManaged
    path_profile = $profilePath
    installed_utc = [DateTime]::UtcNow.ToString("o")
}
[IO.File]::WriteAllText($manifestPath, ($current | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

$versionOutput = & pwsh -NoLogo -NoProfile -NonInteractive -File $target version 2>&1
if ($LASTEXITCODE -ne 0) { throw "Installed CLI self-check failed: $($versionOutput -join '; ')" }
[pscustomobject]@{
    Installed = $true
    Version = [string]$product.version
    Identity = $identity
    Platform = $platform
    InstallRoot = $root
    ControllerRoot = $controllerRoot
    Bin = $binRoot
    Command = $unixShim
    PathUpdated = -not $NoPath
    RestartShell = (-not $NoPath -and $platform -ne "windows")
}

[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "AgentLocalCI"),
    [switch]$NoPath,
    [switch]$Force,
    [switch]$Uninstall
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion -lt [Version]"7.4") { throw "AgentLocalCI requires PowerShell 7.4 or newer" }

function Get-SafeRoot([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $drive = [IO.Path]::GetPathRoot($full)
    if ($full -eq $drive -or ($full.Substring($drive.Length).Trim([char[]]@('\', '/')) -split '[\\/]').Count -lt 2) { throw "AgentLocalCI refuses a broad install root: $full" }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "AgentLocalCI refuses reparse-point install paths: $cursor" }
        }
        if ($cursor -eq $drive) { break }
        $cursor = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($cursor)) { $cursor = $drive }
    }
    return $full
}

function Update-UserPath([string]$Directory, [bool]$Add) {
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $normalized = [IO.Path]::GetFullPath($Directory).TrimEnd([char[]]@('\', '/'))
    $kept = @($parts | Where-Object {
        try { -not ([IO.Path]::GetFullPath($_).TrimEnd([char[]]@('\', '/')).Equals($normalized, [StringComparison]::OrdinalIgnoreCase)) }
        catch { $true }
    })
    if ($Add) { $kept += $normalized }
    [Environment]::SetEnvironmentVariable("Path", ($kept -join ';'), "User")
    if ($Add -and -not (($env:Path -split ';') -contains $normalized)) { $env:Path = "$normalized;$env:Path" }
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

$root = Get-SafeRoot $InstallRoot
$binRoot = Join-Path $root "bin"
if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        [pscustomobject]@{ Uninstalled = $false; Reason = "not installed"; InstallRoot = $root }
        exit 0
    }
    $manifestPath = Join-Path $root "current.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Refusing to uninstall a directory without an AgentLocalCI ownership manifest" }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20 }
    catch { throw "Refusing to uninstall a directory with an invalid AgentLocalCI ownership manifest" }
    if (
        [string]$manifest.product -cne "AgentLocalCI" -or
        [int]$manifest.schema_version -ne 1 -or
        [string]$manifest.identity -cnotmatch '^[0-9a-f]{20}$'
    ) { throw "Refusing to uninstall a directory not proven to be owned by AgentLocalCI" }
    $controllerRoot = [IO.Path]::GetFullPath([string]$manifest.controller_root).TrimEnd([char[]]@('\', '/'))
    $ownedPrefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $controllerRoot.StartsWith($ownedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to uninstall because the controller escaped the AgentLocalCI root" }
    Update-UserPath $binRoot $false
    $backup = "$root.uninstalled-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    Move-Item -LiteralPath $root -Destination $backup
    [pscustomobject]@{ Uninstalled = $true; Backup = $backup; ReportsPreserved = $true }
    exit 0
}

$sourceModule = Join-Path $PSScriptRoot "src\AgentLocalCI"
$sourceCli = Join-Path $PSScriptRoot "bin\agentlocalci.ps1"
$defaultPolicy = Join-Path $PSScriptRoot "config\default-policy.yml"
foreach ($required in @($sourceModule, $sourceCli, $defaultPolicy)) { if (-not (Test-Path -LiteralPath $required)) { throw "Installer source is incomplete: $required" } }
$product = Get-Content -LiteralPath (Join-Path $sourceModule "product.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$sourceInventory = Get-FileInventory $sourceModule "src/AgentLocalCI"
$sourceCliItem = Get-Item -LiteralPath $sourceCli -Force
if (($sourceCliItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "AgentLocalCI refuses a reparse-point CLI source" }
if ($sourceInventory.ContainsKey("bin/agentlocalci.ps1")) { throw "Duplicate CLI inventory path" }
$sourceInventory.Add("bin/agentlocalci.ps1", (Get-FileHash -LiteralPath $sourceCli -Algorithm SHA256).Hash.ToLowerInvariant())
$parts = New-Object System.Collections.Generic.List[string]
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
    if (-not $Force) {
        $existingInventory = Get-FileInventory $controllerRoot
        Assert-FileInventoriesEqual $sourceInventory $existingInventory
    }
    else {
        Remove-Item -LiteralPath $controllerRoot -Recurse -Force
        if (Test-Path -LiteralPath $controllerRoot) { throw "Forced repair could not prove removal of the previous controller identity" }
    }
}
if (-not (Test-Path -LiteralPath $controllerRoot)) {
    [IO.Directory]::CreateDirectory((Join-Path $controllerRoot "src")) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $controllerRoot "bin")) | Out-Null
    Copy-Item -LiteralPath $sourceModule -Destination (Join-Path $controllerRoot "src\AgentLocalCI") -Recurse
    Copy-Item -LiteralPath $sourceCli -Destination (Join-Path $controllerRoot "bin\agentlocalci.ps1")
}
$installedInventory = Get-FileInventory $controllerRoot
Assert-FileInventoriesEqual $sourceInventory $installedInventory

$shimPs1 = @"
`$target = '$($controllerRoot.Replace("'", "''"))\bin\agentlocalci.ps1'
if (-not (Test-Path -LiteralPath `$target -PathType Leaf)) { [Console]::Error.WriteLine('AgentLocalCI controller is missing'); exit 3 }
& pwsh.exe -NoLogo -NoProfile -NonInteractive -File `$target @args
exit `$LASTEXITCODE
"@
$shimCmd = "@pwsh.exe -NoLogo -NoProfile -NonInteractive -File `"$controllerRoot\bin\agentlocalci.ps1`" %* & call exit /b %%errorlevel%%`r`n"
[IO.File]::WriteAllText((Join-Path $binRoot "agentlocalci.ps1"), $shimPs1, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $binRoot "agentlocalci.cmd"), $shimCmd, [Text.ASCIIEncoding]::new())
$tombstone = Join-Path $root "UNINSTALLED.txt"
if (Test-Path -LiteralPath $tombstone -PathType Leaf) { Remove-Item -LiteralPath $tombstone -Force }
if (-not (Test-Path -LiteralPath (Join-Path $root "policy.yml"))) { Copy-Item -LiteralPath $defaultPolicy -Destination (Join-Path $root "policy.yml") }
$current = [ordered]@{ product = "AgentLocalCI"; schema_version = 1; version = [string]$product.version; identity = $identity; controller_root = $controllerRoot; installed_utc = [DateTime]::UtcNow.ToString("o") }
[IO.File]::WriteAllText((Join-Path $root "current.json"), ($current | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
if (-not $NoPath) { Update-UserPath $binRoot $true }

$versionOutput = & pwsh.exe -NoLogo -NoProfile -NonInteractive -File (Join-Path $controllerRoot "bin\agentlocalci.ps1") version 2>&1
if ($LASTEXITCODE -ne 0) { throw "Installed CLI self-check failed: $($versionOutput -join '; ')" }
[pscustomobject]@{ Installed = $true; Version = [string]$product.version; Identity = $identity; InstallRoot = $root; ControllerRoot = $controllerRoot; Bin = $binRoot; PathUpdated = -not $NoPath }

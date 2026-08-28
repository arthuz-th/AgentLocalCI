[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$installer = Join-Path $repoRoot "install.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-installer-" + [Guid]::NewGuid().ToString("N"))
$installRoot = Join-Path $testRoot "installed/AgentLocalCI"
$secondInstallRoot = Join-Path $testRoot "second/AgentLocalCI"
$unrelatedRoot = Join-Path $testRoot "unrelated/directory"
$otherProductRoot = Join-Path $testRoot "other-product"
$pwshCommand = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$originalUserPath = if ($IsWindows) { [Environment]::GetEnvironmentVariable("Path", "User") } else { "" }

function Invoke-PwshFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $output = @(& $pwshCommand -NoLogo -NoProfile -NonInteractive -File $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) { throw "pwsh file failed with exit $exitCode`: $($output -join '; ')" }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Invoke-InstalledCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $command = if ($IsWindows) { Join-Path $Root "bin/agentlocalci.cmd" } else { Join-Path $Root "bin/agentlocalci" }
    $output = if ($IsWindows) {
        @(& $command @Arguments 2>&1 | ForEach-Object { [string]$_ })
    }
    else {
        @(& /bin/sh $command @Arguments 2>&1 | ForEach-Object { [string]$_ })
    }
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) { throw "installed command failed with exit $exitCode`: $($output -join '; ')" }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Command = $command }
}

try {
    [IO.Directory]::CreateDirectory($otherProductRoot) | Out-Null
    $otherMarker = Join-Path $otherProductRoot "other-ci.txt"
    [IO.File]::WriteAllText($otherMarker, "other`n", [Text.UTF8Encoding]::new($false))
    $otherHash = (Get-FileHash -LiteralPath $otherMarker -Algorithm SHA256).Hash

    [IO.Directory]::CreateDirectory($unrelatedRoot) | Out-Null
    $unrelatedMarker = Join-Path $unrelatedRoot "keep.txt"
    [IO.File]::WriteAllText($unrelatedMarker, "retain", [Text.UTF8Encoding]::new($false))
    $refused = Invoke-PwshFile $installer @("-InstallRoot", $unrelatedRoot, "-NoPath", "-Uninstall") -AllowFailure
    if ($refused.ExitCode -eq 0) { throw "installer uninstall accepted an unrelated directory" }
    if (-not (Test-Path -LiteralPath $unrelatedMarker -PathType Leaf)) { throw "installer uninstall moved or deleted unrelated data" }

    [void](Invoke-PwshFile $installer @("-InstallRoot", $installRoot, "-NoPath"))
    $manifestPath = Join-Path $installRoot "current.json"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    if (
        [string]$manifest.product -cne "AgentLocalCI" -or
        [string]$manifest.version -cne "0.2.0-beta.1" -or
        [string]$manifest.identity -cnotmatch '^[0-9a-f]{20}$' -or
        [string]$manifest.host_platform -notin @("windows", "macos", "linux") -or
        [bool]$manifest.path_managed
    ) { throw "installed ownership manifest is invalid" }
    $identity = [string]$manifest.identity
    $version = Invoke-InstalledCommand $installRoot @("version")
    if (($version.Output -join "`n") -notmatch '^AgentLocalCI 0\.2\.0-beta\.1') { throw "installed command self-check failed" }
    if (-not (Test-Path -LiteralPath (Join-Path $installRoot "bin/agentlocalci") -PathType Leaf)) { throw "portable shell command shim is missing" }
    if ($IsWindows -and [Environment]::GetEnvironmentVariable("Path", "User") -cne $originalUserPath) { throw "-NoPath changed the user PATH" }

    [void](Invoke-PwshFile $installer @("-InstallRoot", $installRoot, "-NoPath"))
    $repeatManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    if ([string]$repeatManifest.identity -cne $identity) { throw "repeated install changed an identical controller identity" }

    $installedProductPath = Join-Path ([string]$repeatManifest.controller_root) "src/AgentLocalCI/product.json"
    [IO.File]::AppendAllText($installedProductPath, "`ncorrupted", [Text.UTF8Encoding]::new($false))
    $corruptHash = (Get-FileHash -LiteralPath $installedProductPath -Algorithm SHA256).Hash
    $corruptRefused = Invoke-PwshFile $installer @("-InstallRoot", $installRoot, "-NoPath") -AllowFailure
    if ($corruptRefused.ExitCode -eq 0) { throw "repeated install silently accepted a modified controller identity" }
    if ((Get-FileHash -LiteralPath $installedProductPath -Algorithm SHA256).Hash -cne $corruptHash) { throw "non-force install modified a corrupt controller instead of failing closed" }

    [void](Invoke-PwshFile $installer @("-InstallRoot", $installRoot, "-NoPath", "-Force"))
    $repairManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    if ([string]$repairManifest.identity -cne $identity) { throw "forced repair changed an identical controller identity" }
    if ((Get-FileHash -LiteralPath $installedProductPath -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath (Join-Path $repoRoot "src/AgentLocalCI/product.json") -Algorithm SHA256).Hash) { throw "forced repair did not restore exact controller content" }
    if ((Get-FileHash -LiteralPath $otherMarker -Algorithm SHA256).Hash -cne $otherHash) { throw "install or repair modified a foreign product file" }

    $uninstall = Invoke-InstalledCommand $installRoot @("uninstall", "--home", $installRoot)
    $backups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $installRoot) -Directory -Filter ((Split-Path -Leaf $installRoot) + '.uninstalled-*'))
    if ($backups.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $backups[0].FullName "current.json") -PathType Leaf)) { throw "CLI uninstall did not preserve exactly one recoverable backup" }
    if ($IsWindows) {
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot "UNINSTALLED.txt") -PathType Leaf)) { throw "Windows CLI uninstall did not leave its command-shim tombstone" }
        if ((Test-Path -LiteralPath (Join-Path $installRoot "current.json")) -or (Test-Path -LiteralPath (Join-Path $installRoot "controller"))) { throw "Windows CLI uninstall left active controller state" }
        $removedCommand = Invoke-InstalledCommand $installRoot @("version") -AllowFailure
        if ($removedCommand.ExitCode -eq 0) { throw "Windows tombstone still executed an active controller" }
    }
    elseif (Test-Path -LiteralPath $installRoot) { throw "Unix CLI uninstall left the active install root" }

    [void](Invoke-PwshFile $installer @("-InstallRoot", $installRoot, "-NoPath"))
    $reinstalledVersion = Invoke-InstalledCommand $installRoot @("version")
    if (($reinstalledVersion.Output -join "`n") -notmatch '^AgentLocalCI 0\.2\.0-beta\.1') { throw "reinstall after CLI uninstall failed" }

    [void](Invoke-PwshFile $installer @("-InstallRoot", $secondInstallRoot, "-NoPath"))
    [void](Invoke-PwshFile $installer @("-InstallRoot", $secondInstallRoot, "-NoPath", "-Uninstall"))
    if (Test-Path -LiteralPath $secondInstallRoot) { throw "installer uninstall left the original install root" }
    $secondBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $secondInstallRoot) -Directory -Filter ((Split-Path -Leaf $secondInstallRoot) + '.uninstalled-*'))
    if ($secondBackups.Count -ne 1) { throw "installer uninstall did not create exactly one recoverable backup" }
    if ((Get-FileHash -LiteralPath $otherMarker -Algorithm SHA256).Hash -cne $otherHash) { throw "uninstall modified a foreign product file" }
    if ($IsWindows -and [Environment]::GetEnvironmentVariable("Path", "User") -cne $originalUserPath) { throw "installer lifecycle changed the user PATH despite -NoPath" }

    Write-Output "PASS cross-platform install, repeat install, repair, side-by-side isolation, guarded uninstall, shims, and recoverable backup"
}
finally {
    if ($IsWindows -and [Environment]::GetEnvironmentVariable("Path", "User") -cne $originalUserPath) { [Environment]::SetEnvironmentVariable("Path", $originalUserPath, "User") }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

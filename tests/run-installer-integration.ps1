[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$installer = Join-Path $repoRoot "install.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-installer-" + [Guid]::NewGuid().ToString("N"))
$installRoot = Join-Path $testRoot "installed\AgentLocalCI"
$secondInstallRoot = Join-Path $testRoot "second\AgentLocalCI"
$unrelatedRoot = Join-Path $testRoot "unrelated\directory"
$otherProductRoot = Join-Path $testRoot "other-product"
$originalUserPath = [Environment]::GetEnvironmentVariable("Path", "User")

function Invoke-PwshFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $output = @(& pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) { throw "pwsh file failed with exit $exitCode`: $($output -join '; ')" }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

try {
    [IO.Directory]::CreateDirectory($otherProductRoot) | Out-Null
    $otherMarker = Join-Path $otherProductRoot "other-ci.cmd"
    [IO.File]::WriteAllText($otherMarker, "@echo other`r`n", [Text.ASCIIEncoding]::new())
    $otherHash = (Get-FileHash -LiteralPath $otherMarker -Algorithm SHA256).Hash

    [IO.Directory]::CreateDirectory($unrelatedRoot) | Out-Null
    $unrelatedMarker = Join-Path $unrelatedRoot "keep.txt"
    [IO.File]::WriteAllText($unrelatedMarker, "retain", [Text.UTF8Encoding]::new($false))
    $refused = Invoke-PwshFile $installer @("-InstallRoot", $unrelatedRoot, "-NoPath", "-Uninstall") -AllowFailure
    if ($refused.ExitCode -eq 0) { throw "installer uninstall accepted an unrelated directory" }
    if (-not (Test-Path -LiteralPath $unrelatedMarker -PathType Leaf)) { throw "installer uninstall moved or deleted unrelated data" }

    $first = Invoke-PwshFile $installer @("-InstallRoot", $installRoot, "-NoPath")
    $manifestPath = Join-Path $installRoot "current.json"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    if ([string]$manifest.product -cne "AgentLocalCI" -or [string]$manifest.identity -cnotmatch '^[0-9a-f]{20}$') { throw "installed ownership manifest is invalid" }
    $identity = [string]$manifest.identity
    $cmd = Join-Path $installRoot "bin\agentlocalci.cmd"
    $version = @(& $cmd version 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or ($version -join "`n") -notmatch '^AgentLocalCI 0\.1\.0-alpha\.1') { throw "installed command self-check failed" }
    if ([Environment]::GetEnvironmentVariable("Path", "User") -cne $originalUserPath) { throw "-NoPath changed the user PATH" }

    $repeat = Invoke-PwshFile $installer @("-InstallRoot", $installRoot, "-NoPath")
    $repeatManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    if ([string]$repeatManifest.identity -cne $identity) { throw "repeated install changed an identical controller identity" }

    $installedProductPath = Join-Path ([string]$repeatManifest.controller_root) "src\AgentLocalCI\product.json"
    [IO.File]::AppendAllText($installedProductPath, "`ncorrupted", [Text.UTF8Encoding]::new($false))
    $corruptHash = (Get-FileHash -LiteralPath $installedProductPath -Algorithm SHA256).Hash
    $corruptRefused = Invoke-PwshFile $installer @("-InstallRoot", $installRoot, "-NoPath") -AllowFailure
    if ($corruptRefused.ExitCode -eq 0) { throw "repeated install silently accepted a modified controller identity" }
    if ((Get-FileHash -LiteralPath $installedProductPath -Algorithm SHA256).Hash -cne $corruptHash) { throw "non-force install modified a corrupt controller instead of failing closed" }

    $repair = Invoke-PwshFile $installer @("-InstallRoot", $installRoot, "-NoPath", "-Force")
    $repairManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    if ([string]$repairManifest.identity -cne $identity) { throw "forced repair changed an identical controller identity" }
    if ((Get-FileHash -LiteralPath $installedProductPath -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath (Join-Path $repoRoot "src\AgentLocalCI\product.json") -Algorithm SHA256).Hash) { throw "forced repair did not restore exact controller content" }
    if ((Get-FileHash -LiteralPath $otherMarker -Algorithm SHA256).Hash -cne $otherHash) { throw "install or repair modified a foreign product file" }

    $uninstallOutput = @(& $cmd uninstall --home $installRoot 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "CLI uninstall failed: $($uninstallOutput -join '; ')" }
    if (-not (Test-Path -LiteralPath (Join-Path $installRoot "UNINSTALLED.txt") -PathType Leaf)) { throw "CLI uninstall did not leave its safe Windows command-shim tombstone" }
    if ((Test-Path -LiteralPath (Join-Path $installRoot "current.json")) -or (Test-Path -LiteralPath (Join-Path $installRoot "controller"))) { throw "CLI uninstall left active controller state in the tombstone root" }
    $backups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $installRoot) -Directory -Filter ((Split-Path -Leaf $installRoot) + '.uninstalled-*'))
    if ($backups.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $backups[0].FullName "current.json") -PathType Leaf)) { throw "CLI uninstall did not preserve a recoverable backup" }
    $removedCommand = @(& $cmd version 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -eq 0) { throw "CLI tombstone still executed an active controller" }

    Invoke-PwshFile $installer @("-InstallRoot", $installRoot, "-NoPath") | Out-Null
    if (Test-Path -LiteralPath (Join-Path $installRoot "UNINSTALLED.txt")) { throw "reinstall did not remove the CLI tombstone" }
    $reinstalledVersion = @(& $cmd version 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or ($reinstalledVersion -join "`n") -notmatch '^AgentLocalCI 0\.1\.0-alpha\.1') { throw "reinstall over the tombstone failed" }

    Invoke-PwshFile $installer @("-InstallRoot", $secondInstallRoot, "-NoPath") | Out-Null
    $scriptUninstall = Invoke-PwshFile $installer @("-InstallRoot", $secondInstallRoot, "-NoPath", "-Uninstall")
    if (Test-Path -LiteralPath $secondInstallRoot) { throw "installer uninstall left the original install root" }
    $secondBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $secondInstallRoot) -Directory -Filter ((Split-Path -Leaf $secondInstallRoot) + '.uninstalled-*'))
    if ($secondBackups.Count -ne 1) { throw "installer uninstall did not create exactly one recoverable backup" }
    if ((Get-FileHash -LiteralPath $otherMarker -Algorithm SHA256).Hash -cne $otherHash) { throw "uninstall modified a foreign product file" }
    if ([Environment]::GetEnvironmentVariable("Path", "User") -cne $originalUserPath) { throw "installer lifecycle changed the user PATH despite -NoPath" }

    Write-Output "PASS install, repeat install, repair, side-by-side isolation, guarded uninstall, and recoverable backup"
}
finally {
    if ([Environment]::GetEnvironmentVariable("Path", "User") -cne $originalUserPath) {
        [Environment]::SetEnvironmentVariable("Path", $originalUserPath, "User")
    }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

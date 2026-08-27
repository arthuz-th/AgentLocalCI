function Get-AgentLocalCiRepositoryRoot {
    param([AllowNull()][string]$RepositoryRoot)
    $candidate = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { (Get-Location).Path } else { $RepositoryRoot }
    $full = Get-AgentLocalCiSafeFullPath $candidate
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { Throw-AgentLocalCi -Message "Repository does not exist: $full" -ExitCode 2 }
    $git = Get-AgentLocalCiGitPath
    $probe = Invoke-AgentLocalCiNative -FilePath $git -Arguments @("--no-pager", "--no-replace-objects", "-c", "core.hooksPath=NUL", "-c", "core.attributesFile=NUL", "-C", $full, "rev-parse", "--show-toplevel") -AllowFailure -Environment @{ GIT_CONFIG_NOSYSTEM = "1"; GIT_CONFIG_GLOBAL = "NUL"; GIT_TERMINAL_PROMPT = "0"; GIT_OPTIONAL_LOCKS = "0" } -RemoveEnvironmentPrefixes @("GIT_")
    if ($probe.ExitCode -ne 0) { Throw-AgentLocalCi -Message "RepositoryRoot is not a Git worktree: $full" -ExitCode 2 }
    $top = Get-AgentLocalCiSafeFullPath ($probe.Lines | Select-Object -First 1)
    if (-not $top.Equals($full, [StringComparison]::OrdinalIgnoreCase)) { Throw-AgentLocalCi -Message "RepositoryRoot must be the Git worktree root: $top" -ExitCode 2 }
    return $full
}

function Get-AgentLocalCiSourceAssets {
    $root = Join-Path $script:AgentLocalCiModuleRoot "Container"
    $assets = [ordered]@{
        Dockerfile = Join-Path $root "Dockerfile"
        Entrypoint = Join-Path $root "entrypoint.sh"
        Runner = Join-Path $root "runner.ps1"
        Proxy = Join-Path $root "proxy.mjs"
        ProxyHealth = Join-Path $root "proxy-health.mjs"
        NetworkProbe = Join-Path $root "network-probe.mjs"
        GradleResolver = Join-Path $root "resolve-dependencies.gradle"
    }
    foreach ($asset in $assets.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $asset.Value -PathType Leaf)) { Throw-AgentLocalCi -Message "Controller asset is missing: $($asset.Value)" -ExitCode 3 }
    }
    return [pscustomobject]$assets
}

function Get-AgentLocalCiContext {
    param(
        [AllowNull()][string]$Home,
        [AllowNull()][string]$RepositoryRoot,
        [AllowNull()][string]$PolicyPath,
        [switch]$RepositoryOptional
    )
    $repository = $null
    if ($RepositoryOptional -and [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        try { $repository = Get-AgentLocalCiRepositoryRoot $null } catch { $repository = $null }
    }
    else {
        $repository = Get-AgentLocalCiRepositoryRoot $RepositoryRoot
    }
    $homeRoot = Assert-AgentLocalCiPathIsNarrow $(if ([string]::IsNullOrWhiteSpace($Home)) { Get-AgentLocalCiDefaultHome } else { $Home })
    if ($null -ne $repository -and ((Test-AgentLocalCiPathContained $homeRoot $repository) -or (Test-AgentLocalCiPathContained $repository $homeRoot))) { Throw-AgentLocalCi -Message "AgentLocalCI home and target repository must not contain one another" -ExitCode 4 }
    if (-not (Test-Path -LiteralPath $homeRoot)) { [IO.Directory]::CreateDirectory($homeRoot) | Out-Null }
    Assert-AgentLocalCiNoReparseAncestor $homeRoot
    $runtime = New-AgentLocalCiOwnedDirectory (Join-Path $homeRoot "runtime") $homeRoot
    $runs = New-AgentLocalCiOwnedDirectory (Join-Path $runtime "runs") $runtime
    $locks = New-AgentLocalCiOwnedDirectory (Join-Path $runtime "locks") $runtime
    $build = New-AgentLocalCiOwnedDirectory (Join-Path $runtime "trusted-build") $runtime
    $scratch = New-AgentLocalCiOwnedDirectory (Join-Path $runtime "scratch") $runtime
    $resolvedPolicy = Get-AgentLocalCiSafeFullPath $(if ([string]::IsNullOrWhiteSpace($PolicyPath)) { Join-Path $homeRoot "policy.yml" } else { $PolicyPath })
    if (-not (Test-AgentLocalCiPathContained $resolvedPolicy $homeRoot)) { Throw-AgentLocalCi -Message "Machine policy must be inside AgentLocalCI home" -ExitCode 4 }
    return [pscustomobject]@{
        Home = $homeRoot
        RepositoryRoot = $repository
        RuntimeRoot = $runtime
        RunsRoot = $runs
        LocksRoot = $locks
        BuildRoot = $build
        ScratchRoot = $scratch
        PolicyPath = $resolvedPolicy
        Policy = Read-AgentLocalCiPolicy $resolvedPolicy
        Assets = Get-AgentLocalCiSourceAssets
    }
}

function Get-AgentLocalCiControllerIdentity {
    param([Parameter(Mandatory = $true)][object]$Context)
    $inventory = [Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($file in @(Get-ChildItem -LiteralPath $script:AgentLocalCiModuleRoot -File -Recurse | Sort-Object FullName)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-AgentLocalCi -Message "Controller identity refuses reparse-point module content" -ExitCode 4
        }
        $relative = [IO.Path]::GetRelativePath($script:AgentLocalCiModuleRoot, $file.FullName).Replace([char]92, '/')
        $inventory.Add("src/AgentLocalCI/$relative", (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    $cliPath = [IO.Path]::GetFullPath((Join-Path $script:AgentLocalCiModuleRoot "..\..\bin\agentlocalci.ps1"))
    if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
        Throw-AgentLocalCi -Message "Controller CLI entry point is missing from the identity boundary" -ExitCode 3
    }
    $cliItem = Get-Item -LiteralPath $cliPath -Force
    if (($cliItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-AgentLocalCi -Message "Controller identity refuses a reparse-point CLI entry point" -ExitCode 4
    }
    $inventory.Add("bin/agentlocalci.ps1", (Get-FileHash -LiteralPath $cliPath -Algorithm SHA256).Hash.ToLowerInvariant())
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add("AgentLocalCI/$script:AgentLocalCiVersion")
    foreach ($entry in $inventory.GetEnumerator()) { $parts.Add("$($entry.Key):$($entry.Value)") }
    return (Get-AgentLocalCiStringSha256 ($parts -join "`n")).Substring(0, 20)
}

function Write-AgentLocalCiDefaultPolicy {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) { return }
    $policy = New-AgentLocalCiDefaultPolicy
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, ($policy | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}

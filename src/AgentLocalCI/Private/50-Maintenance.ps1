function Invoke-AgentLocalCiDoctor {
    param(
        [AllowNull()][string]$Home,
        [AllowNull()][string]$RepositoryRoot,
        [AllowNull()][string]$PolicyPath,
        [switch]$BuildImage
    )
    $checks = [Collections.Generic.List[object]]::new()
    $add = {
        param($Name, $Passed, $Detail, $Fix = "")
        $checks.Add([pscustomobject]@{
            name = [string]$Name
            passed = [bool]$Passed
            detail = ConvertTo-AgentLocalCiSafeDisplayText ([string]$Detail) 1000
            fix = ConvertTo-AgentLocalCiSafeDisplayText ([string]$Fix) 1000
        })
    }

    $platform = Get-AgentLocalCiPlatformSupport
    & $add "platform" $platform.Supported ("{0} / {1}; support={2}" -f $platform.Platform, (Get-AgentLocalCiHostArchitecture), $platform.Status) $(if ($platform.Supported) { "" } else { "Use Windows, macOS, or Linux with PowerShell 7 and a Linux Docker engine." })

    $powershellPassed = $PSVersionTable.PSVersion -ge [Version]"7.4"
    $powershellFix = switch ($platform.Platform) {
        "macos" { "Install or upgrade with Homebrew: brew install powershell" }
        "windows" { "Install PowerShell 7.4 or newer from Microsoft, then open a new terminal." }
        "linux" { "Install PowerShell 7.4 or newer from Microsoft's package repository." }
        default { "Install PowerShell 7.4 or newer." }
    }
    & $add "powershell" $powershellPassed $PSVersionTable.PSVersion.ToString() $(if ($powershellPassed) { "" } else { $powershellFix })

    try {
        $git = Invoke-AgentLocalCiNative (Get-AgentLocalCiGitPath) @("--version")
        & $add "git" $true $git.Text.Trim() ""
    }
    catch {
        $fix = if ($platform.Platform -ceq "macos") { "Install Apple's command-line tools with: xcode-select --install" } else { "Install Git and make sure the git command is on PATH." }
        & $add "git" $false $_.Exception.Message $fix
    }

    $dockerPassed = $false
    try {
        $dockerVersion = (Invoke-AgentLocalCiDocker @("version", "--format", "{{json .}}" )).Text | ConvertFrom-Json -Depth 20
        $dockerInfo = (Invoke-AgentLocalCiDocker @("info", "--format", "{{json .}}" )).Text | ConvertFrom-Json -Depth 20
        $architecture = Get-AgentLocalCiDockerArchitecture
        $dockerPassed = [string]$dockerInfo.OSType -ceq "linux" -and $architecture -in @("amd64", "arm64")
        & $add "docker-linux-server" $dockerPassed ("client {0}; server {1}; OS {2}; arch {3}; CPUs {4}; memory {5:N1} GiB" -f $dockerVersion.Client.Version, $dockerVersion.Server.Version, $dockerInfo.OSType, $architecture, $dockerInfo.NCPU, ([double]$dockerInfo.MemTotal / 1GB)) $(if ($dockerPassed) { "" } else { "Switch Docker to Linux containers and use an amd64 or arm64 Docker engine." })
    }
    catch {
        $fix = if ($platform.Platform -ceq "macos") { "Install and start Docker Desktop for Mac, then wait until 'docker info' succeeds." } else { "Install and start Docker Desktop or another compatible Linux Docker engine." }
        & $add "docker-linux-server" $false $_.Exception.Message $fix
    }

    $context = $null
    try {
        $context = Get-AgentLocalCiContext $Home $RepositoryRoot $PolicyPath -RepositoryOptional
        & $add "machine-policy" $true ("schema {0}; enabled={1}; executor={2}" -f $context.Policy.schema_version, $context.Policy.enabled, $context.Policy.executor) ""
        & $add "controller-assets" $true ("identity " + (Get-AgentLocalCiControllerIdentity $context)) ""
        $freeGiB = [Math]::Round((Get-AgentLocalCiFreeDiskBytes $context.Home) / 1GB, 1)
        $diskPassed = $freeGiB -ge [double]$context.Policy.resources.minimum_free_disk_gib
        & $add "free-disk" $diskPassed ("$freeGiB GiB available; policy minimum $($context.Policy.resources.minimum_free_disk_gib) GiB") $(if ($diskPassed) { "" } else { "Free disk space or lower the machine-policy minimum after reviewing the risk." })
        if ($BuildImage -and $dockerPassed) {
            $image = Get-AgentLocalCiTrustedImage $context
            & $add "trusted-image" $true ("{0}; controller {1}; linux/{2}" -f $image.Id.Substring(0, [Math]::Min(19, $image.Id.Length)), $image.Identity, $image.Architecture) ""
        }
    }
    catch { & $add "controller-context" $false $_.Exception.Message "Run this command from a Git repository or pass --repository PATH; keep the AgentLocalCI home outside the repository." }

    if ($null -ne $context -and $dockerPassed) {
        $doctorRunId = New-AgentLocalCiRunId
        $doctorResources = [Collections.Generic.List[object]]::new()
        try {
            $networkName = "$(Get-AgentLocalCiDockerPrefix $doctorRunId)-doctor-net"
            New-AgentLocalCiDockerNetwork $networkName $doctorRunId $doctorResources | Out-Null
            & $add "dependency-network-isolation" $true "internal bridge, isolated IPv4 gateway, IPv6 disabled" ""
        }
        catch { & $add "dependency-network-isolation" $false $_.Exception.Message "Update Docker Desktop and ensure the current engine supports isolated internal bridge networks." }
        finally {
            $doctorCleanup = Remove-AgentLocalCiResources $doctorResources
            & $add "doctor-resource-cleanup" $doctorCleanup.Passed $(if ($doctorCleanup.Passed) { "all doctor-owned Docker resources removed and absence verified" } else { $doctorCleanup.Failures -join "; " }) $(if ($doctorCleanup.Passed) { "" } else { "Run 'agentlocalci clean' and inspect any retained owner-labelled resource before continuing." })
        }
    }

    return [pscustomobject]@{
        Passed = (@($checks | Where-Object { -not $_.passed }).Count -eq 0)
        Platform = $platform.Platform
        SupportStatus = $platform.Status
        Checks = $checks.ToArray()
    }
}

function Test-AgentLocalCiTrackedResourceShape {
    param(
        [AllowNull()][object]$Resource,
        [Parameter(Mandatory = $true)][string]$ExpectedRunId
    )
    if ($null -eq $Resource -or -not (Test-AgentLocalCiRunId $ExpectedRunId)) { return $false }
    return (
        [string]$Resource.Type -cin @("container", "network", "volume") -and
        [string]$Resource.Name -cmatch '^[a-z0-9][a-z0-9_.-]{1,126}$' -and
        [string]$Resource.Kind -cmatch '^[a-z0-9][a-z0-9_.-]{0,126}$' -and
        [string]$Resource.RunId -ceq $ExpectedRunId
    )
}

function Get-AgentLocalCiRecordedRunResources {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $resources = [Collections.Generic.List[object]]::new()
    $property = $State.PSObject.Properties["docker_resources"]
    if ($null -eq $property -or $null -eq $property.Value) { return ,$resources }
    foreach ($record in @($property.Value)) {
        $candidate = [pscustomobject]@{
            Type = [string]$record.type
            Name = [string]$record.name
            Kind = [string]$record.kind
            RunId = [string]$record.run_id
        }
        if (-not (Test-AgentLocalCiTrackedResourceShape $candidate $RunId)) {
            Throw-AgentLocalCi -Message "Run '$RunId' contains an invalid recorded Docker resource" -ExitCode 5
        }
        $resources.Add($candidate)
    }
    return ,$resources
}

function Get-AgentLocalCiDockerResourcesForRun {
    param([Parameter(Mandatory = $true)][string]$RunId)
    if (-not (Test-AgentLocalCiRunId $RunId)) { Throw-AgentLocalCi -Message "Invalid run identity during Docker recovery" -ExitCode 5 }
    $resources = [Collections.Generic.List[object]]::new()
    $specifications = @(
        [pscustomobject]@{ Type = "container"; Command = @("container", "ls", "--all", "--filter", "label=io.agentlocalci.owner=$script:AgentLocalCiOwnerLabel", "--filter", "label=io.agentlocalci.run=$RunId", "--format", "{{.Names}}") },
        [pscustomobject]@{ Type = "network"; Command = @("network", "ls", "--filter", "label=io.agentlocalci.owner=$script:AgentLocalCiOwnerLabel", "--filter", "label=io.agentlocalci.run=$RunId", "--format", "{{.Name}}") },
        [pscustomobject]@{ Type = "volume"; Command = @("volume", "ls", "--filter", "label=io.agentlocalci.owner=$script:AgentLocalCiOwnerLabel", "--filter", "label=io.agentlocalci.run=$RunId", "--format", "{{.Name}}") }
    )
    foreach ($specification in $specifications) {
        $listing = Invoke-AgentLocalCiDocker ([string[]]$specification.Command) -AllowFailure
        if ($listing.ExitCode -ne 0) { Throw-AgentLocalCi -Message "Docker $($specification.Type) enumeration failed during run recovery" -ExitCode 5 }
        foreach ($rawName in @($listing.Lines)) {
            $name = [string]$rawName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -cnotmatch '^[a-z0-9][a-z0-9_.-]{1,126}$') { Throw-AgentLocalCi -Message "Docker returned an unsafe resource name during cleanup discovery; the resource was retained" -ExitCode 5 }
            $inspectionResult = Invoke-AgentLocalCiDocker @([string]$specification.Type, "inspect", $name) -AllowFailure
            if ($inspectionResult.ExitCode -ne 0) { Throw-AgentLocalCi -Message "Docker $($specification.Type) inspection failed during run recovery" -ExitCode 5 }
            $inspection = ConvertFrom-AgentLocalCiSingleInspection $inspectionResult.Text ([string]$specification.Type)
            $labels = if ([string]$specification.Type -ceq "container") { $inspection.Config.Labels } else { $inspection.Labels }
            $kind = [string]$labels."io.agentlocalci.kind"
            $candidate = [pscustomobject]@{ Type = [string]$specification.Type; Name = [string]$name; Kind = $kind; RunId = $RunId }
            if (
                [string]$labels."io.agentlocalci.owner" -cne $script:AgentLocalCiOwnerLabel -or
                [string]$labels."io.agentlocalci.run" -cne $RunId -or
                -not (Test-AgentLocalCiTrackedResourceShape $candidate $RunId)
            ) {
                Throw-AgentLocalCi -Message "Docker resource labels are ambiguous during run recovery" -ExitCode 5
            }
            $resources.Add($candidate)
        }
    }
    return ,$resources
}

function Get-AgentLocalCiAllOwnedDockerResources {
    $resources = [Collections.Generic.List[object]]::new()
    $specifications = @(
        [pscustomobject]@{ Type = "container"; Command = @("container", "ls", "--all", "--filter", "label=io.agentlocalci.owner=$script:AgentLocalCiOwnerLabel", "--format", "{{.Names}}") },
        [pscustomobject]@{ Type = "network"; Command = @("network", "ls", "--filter", "label=io.agentlocalci.owner=$script:AgentLocalCiOwnerLabel", "--format", "{{.Name}}") },
        [pscustomobject]@{ Type = "volume"; Command = @("volume", "ls", "--filter", "label=io.agentlocalci.owner=$script:AgentLocalCiOwnerLabel", "--format", "{{.Name}}") }
    )
    foreach ($specification in $specifications) {
        $listing = Invoke-AgentLocalCiDocker ([string[]]$specification.Command) -AllowFailure
        if ($listing.ExitCode -ne 0) { Throw-AgentLocalCi -Message "Docker $($specification.Type) enumeration failed during cleanup audit" -ExitCode 5 }
        foreach ($rawName in @($listing.Lines)) {
            $name = [string]$rawName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -cnotmatch '^[a-z0-9][a-z0-9_.-]{1,126}$') { Throw-AgentLocalCi -Message "Docker returned an unsafe resource name during cleanup discovery; the resource was retained" -ExitCode 5 }
            $inspectionResult = Invoke-AgentLocalCiDocker @([string]$specification.Type, "inspect", $name) -AllowFailure
            if ($inspectionResult.ExitCode -ne 0) { Throw-AgentLocalCi -Message "Docker $($specification.Type) inspection failed during cleanup audit" -ExitCode 5 }
            $inspection = ConvertFrom-AgentLocalCiSingleInspection $inspectionResult.Text ([string]$specification.Type)
            $labels = if ([string]$specification.Type -ceq "container") { $inspection.Config.Labels } else { $inspection.Labels }
            $runId = [string]$labels."io.agentlocalci.run"
            $candidate = [pscustomobject]@{
                Type = [string]$specification.Type
                Name = [string]$name
                Kind = [string]$labels."io.agentlocalci.kind"
                RunId = $runId
            }
            if (
                [string]$labels."io.agentlocalci.owner" -cne $script:AgentLocalCiOwnerLabel -or
                -not (Test-AgentLocalCiTrackedResourceShape $candidate $runId)
            ) {
                Throw-AgentLocalCi -Message "An owner-labeled Docker resource has invalid or ambiguous labels; it was retained" -ExitCode 5
            }
            $resources.Add($candidate)
        }
    }
    return ,$resources
}

function Merge-AgentLocalCiRunResources {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Recorded,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Discovered,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $merged = [Collections.Generic.List[object]]::new()
    $byKey = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($candidate in @($Recorded.ToArray()) + @($Discovered.ToArray())) {
        if (-not (Test-AgentLocalCiTrackedResourceShape $candidate $RunId)) { Throw-AgentLocalCi -Message "Invalid tracked resource during run recovery" -ExitCode 5 }
        $key = "$([string]$candidate.Type)|$([string]$candidate.Name)"
        if ($byKey.ContainsKey($key)) {
            $existing = $byKey[$key]
            if ([string]$existing.Kind -cne [string]$candidate.Kind) { Throw-AgentLocalCi -Message "Conflicting Docker resource kind during run recovery" -ExitCode 5 }
            continue
        }
        $byKey.Add($key, $candidate)
        $merged.Add($candidate)
    }
    return ,$merged
}

function Write-AgentLocalCiRecoveredRunState {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$PreviousState,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$RemainingResources
    )
    $records = @($RemainingResources.ToArray() | ForEach-Object {
        [ordered]@{ type = [string]$_.Type; name = [string]$_.Name; kind = [string]$_.Kind; run_id = [string]$_.RunId }
    })
    $state = [ordered]@{
        schema_version = 1
        run_id = ConvertTo-AgentLocalCiSafeDisplayText ([string]$PreviousState.run_id) 64
        status = $Status
        target_sha = ConvertTo-AgentLocalCiSafeDisplayText ([string]$PreviousState.target_sha) 64
        profile = ConvertTo-AgentLocalCiSafeDisplayText ([string]$PreviousState.profile) 64
        controller_process_id = 0
        controller_process_started_utc = ""
        updated_utc = [DateTime]::UtcNow.ToString("o")
        message = ConvertTo-AgentLocalCiSafeDisplayText $Message 1000
        docker_resources = $records
    }
    Write-AgentLocalCiJsonAtomic $StatePath $state
}

function Repair-AgentLocalCiStaleRuns {
    param([Parameter(Mandatory = $true)][object]$Context)
    $repairs = New-Object System.Collections.Generic.List[object]
    foreach ($directory in @(Get-ChildItem -LiteralPath $Context.RunsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if (-not (Test-AgentLocalCiRunId $directory.Name)) { continue }
        $statePath = Join-Path $directory.FullName "state.json"
        try {
            $state = Read-AgentLocalCiJsonFile $statePath
            if ($null -eq $state) { continue }
            if ([string]$state.run_id -cne $directory.Name) { Throw-AgentLocalCi -Message "Run directory and state identity differ" -ExitCode 5 }
            $report = Read-AgentLocalCiJsonFile (Join-Path $directory.FullName "report.json")
            $reportCleanupFailed = $null -ne $report -and $null -ne $report.cleanup -and [string]$report.cleanup.status -ceq "Failed"
            $recoverableState = [string]$state.status -cin @("Queued", "Running", "Stale", "Failed", "InfrastructureFailed", "SafetyBlocked", "Cancelled", "CleanupFailed", "AbandonedCleanupFailed")
            if (-not $reportCleanupFailed -and -not $recoverableState) { continue }
            if ($null -ne $report -and [string]$report.cleanup.status -ceq "Passed") { continue }
            if (Test-AgentLocalCiProcessIdentityAlive ([int]$state.controller_process_id) ([string]$state.controller_process_started_utc)) { continue }

            $recorded = Get-AgentLocalCiRecordedRunResources $state $directory.Name
            $discovered = Get-AgentLocalCiDockerResourcesForRun $directory.Name
            $resources = Merge-AgentLocalCiRunResources $recorded $discovered $directory.Name
            $cleanup = Remove-AgentLocalCiResources $resources
            $remaining = Get-AgentLocalCiDockerResourcesForRun $directory.Name
            $passed = $cleanup.Passed -and $remaining.Count -eq 0
            $status = if ($passed) { if ($reportCleanupFailed) { "CleanupRecovered" } else { "AbandonedRecovered" } } else { "AbandonedCleanupFailed" }
            $message = if ($passed) { "Dead controller detected; exact run-owned Docker resources were removed and absence verified" } else { (@($cleanup.Failures) + @("remaining resources: $($remaining.Count)")) -join "; " }
            Write-AgentLocalCiRecoveredRunState $statePath $state $status $message $remaining
            $repairs.Add([pscustomobject]@{
                run_id = $directory.Name
                passed = $passed
                status = $status
                resource_count = $resources.Count
                remaining_count = $remaining.Count
                failures = @($cleanup.Failures)
            })
        }
        catch {
            $repairs.Add([pscustomobject]@{
                run_id = $directory.Name
                passed = $false
                status = "AbandonedCleanupFailed"
                resource_count = 0
                remaining_count = -1
                failures = @((ConvertTo-AgentLocalCiSafeDisplayText $_.Exception.Message 1000))
            })
        }
    }
    return $repairs.ToArray()
}

function Remove-AgentLocalCiOwnedImages {
    $removed = New-Object System.Collections.Generic.List[string]
    $failures = New-Object System.Collections.Generic.List[string]
    $listing = Invoke-AgentLocalCiDocker @("image", "ls", "--all", "--no-trunc", "--filter", "label=io.agentlocalci.owner=$script:AgentLocalCiOwnerLabel", "--format", "{{.ID}}") -AllowFailure
    if ($listing.ExitCode -ne 0) { return [pscustomobject]@{ Passed = $false; Removed = @(); Failures = @("Docker image enumeration failed") } }
    foreach ($imageReference in @($listing.Lines | Select-Object -Unique | Where-Object { $_ -cmatch '^(?:sha256:)?[0-9a-f]{12,64}$' })) {
        try {
            $inspectionResult = Invoke-AgentLocalCiDocker @("image", "inspect", [string]$imageReference) -AllowFailure
            if ($inspectionResult.ExitCode -ne 0) { $failures.Add("owned image inspection failed"); continue }
            $inspection = ConvertFrom-AgentLocalCiSingleInspection $inspectionResult.Text "image"
            $labels = $inspection.Config.Labels
            if (
                [string]$labels."io.agentlocalci.owner" -cne $script:AgentLocalCiOwnerLabel -or
                [string]$labels."io.agentlocalci.boundary" -cne $script:AgentLocalCiBoundaryMarker -or
                [string]$labels."io.agentlocalci.identity" -cnotmatch '^[0-9a-f]{20}$'
            ) { $failures.Add("owned image labels are ambiguous; image retained"); continue }
            $foreignTags = @($inspection.RepoTags | Where-Object { $_ -and [string]$_ -cnotmatch '^agentlocalci:[0-9a-f]{20}$' })
            if ($foreignTags.Count -gt 0) { $failures.Add("owned image has a non-AgentLocalCI tag and was retained"); continue }
            $removal = Invoke-AgentLocalCiDocker @("image", "rm", [string]$inspection.Id) -AllowFailure
            if ($removal.ExitCode -ne 0) { $failures.Add("owned image removal failed"); continue }
            if ((Invoke-AgentLocalCiDocker @("image", "inspect", [string]$inspection.Id) -AllowFailure).ExitCode -eq 0) { $failures.Add("owned image absence was not proven after removal"); continue }
            $removed.Add([string]$inspection.Id)
        }
        catch { $failures.Add((ConvertTo-AgentLocalCiSafeDisplayText $_.Exception.Message 1000)) }
    }
    return [pscustomobject]@{ Passed = ($failures.Count -eq 0); Removed = $removed.ToArray(); Failures = $failures.ToArray() }
}

function Invoke-AgentLocalCiClean {
    param(
        [AllowNull()][string]$Home,
        [AllowNull()][string]$RepositoryRoot,
        [AllowNull()][string]$PolicyPath,
        [ValidateRange(0, 86400)][int]$WaitSeconds = 0,
        [switch]$Images
    )
    $context = Get-AgentLocalCiContext $Home $RepositoryRoot $PolicyPath -RepositoryOptional
    $maintenanceRunId = New-AgentLocalCiRunId
    $lock = New-AgentLocalCiControllerLock $context $maintenanceRunId $WaitSeconds
    try {
        $failures = New-Object System.Collections.Generic.List[string]
        $repairs = @(Repair-AgentLocalCiStaleRuns $context)
        foreach ($repair in @($repairs | Where-Object { -not $_.passed })) {
            $failures.Add("run $($repair.run_id): $(@($repair.failures) -join '; ')")
        }

        $remainingOwned = $null
        try { $remainingOwned = Get-AgentLocalCiAllOwnedDockerResources }
        catch { $failures.Add((ConvertTo-AgentLocalCiSafeDisplayText $_.Exception.Message 1000)) }
        if ($null -ne $remainingOwned -and $remainingOwned.Count -gt 0) {
            $preview = @($remainingOwned.ToArray() | Select-Object -First 10 | ForEach-Object { "$($_.Type)/$($_.Name)/$($_.RunId)" }) -join ", "
            $failures.Add("scoped recovery left owner-labeled Docker resources; retained: $preview")
        }

        $scratchRemoved = 0
        if ($failures.Count -eq 0) {
            foreach ($item in @(Get-ChildItem -LiteralPath $context.ScratchRoot -Force -ErrorAction SilentlyContinue)) {
                if (-not $item.PSIsContainer -or -not (Test-AgentLocalCiRunId $item.Name)) {
                    $failures.Add("unexpected scratch entry was retained")
                    continue
                }
                $owned = Assert-AgentLocalCiOwnedPath $item.FullName $context.ScratchRoot
                Remove-Item -LiteralPath $owned -Recurse -Force
                if (Test-Path -LiteralPath $owned) { $failures.Add("scratch directory absence was not proven") }
                else { $scratchRemoved++ }
            }
        }

        $imageResult = [pscustomobject]@{ Passed = $true; Removed = @(); Failures = @() }
        $buildDirectoriesRemoved = 0
        if ($Images -and $failures.Count -eq 0) {
            $imageResult = Remove-AgentLocalCiOwnedImages
            foreach ($failure in @($imageResult.Failures)) { $failures.Add([string]$failure) }
            if ($imageResult.Passed) {
                foreach ($item in @(Get-ChildItem -LiteralPath $context.BuildRoot -Force -ErrorAction SilentlyContinue)) {
                    if (-not $item.PSIsContainer -or $item.Name -cnotmatch '^[0-9a-f]{20}$') {
                        $failures.Add("unexpected trusted-build entry was retained")
                        continue
                    }
                    $owned = Assert-AgentLocalCiOwnedPath $item.FullName $context.BuildRoot
                    Remove-Item -LiteralPath $owned -Recurse -Force
                    if (Test-Path -LiteralPath $owned) { $failures.Add("trusted-build directory absence was not proven") }
                    else { $buildDirectoriesRemoved++ }
                }
            }
        }

        return [pscustomobject]@{
            Passed = ($failures.Count -eq 0)
            RecoveredRuns = $repairs
            RemovedScratchDirectories = $scratchRemoved
            RemovedImages = @($imageResult.Removed).Count
            RemovedTrustedBuildDirectories = $buildDirectoriesRemoved
            Failures = $failures.ToArray()
        }
    }
    finally { $lock.Dispose() }
}

function Set-AgentLocalCiServiceState {
    param(
        [AllowNull()][string]$Home,
        [AllowNull()][string]$RepositoryRoot,
        [AllowNull()][string]$PolicyPath,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )
    $context = Get-AgentLocalCiContext $Home $RepositoryRoot $PolicyPath -RepositoryOptional
    $policy = if (Test-Path -LiteralPath $context.PolicyPath -PathType Leaf) { ConvertFrom-AgentLocalCiJsonYaml (Get-Content -LiteralPath $context.PolicyPath -Raw -Encoding UTF8) $context.PolicyPath } else { New-AgentLocalCiDefaultPolicy }
    $policy.enabled = $Enabled
    [void](Assert-AgentLocalCiPolicy $policy)
    Write-AgentLocalCiJsonAtomic $context.PolicyPath $policy
    return [pscustomobject]@{ Enabled = $Enabled; PolicyPath = $context.PolicyPath }
}

function Get-AgentLocalCiServiceState {
    param(
        [AllowNull()][string]$Home,
        [AllowNull()][string]$RepositoryRoot,
        [AllowNull()][string]$PolicyPath
    )
    $context = Get-AgentLocalCiContext $Home $RepositoryRoot $PolicyPath -RepositoryOptional
    return [pscustomobject]@{ Enabled = [bool]$context.Policy.enabled; PolicyPath = $context.PolicyPath; Executor = [string]$context.Policy.executor; OnDemand = $true; Daemon = $false }
}

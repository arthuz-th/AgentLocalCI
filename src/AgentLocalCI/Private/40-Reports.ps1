function New-AgentLocalCiRunDirectories {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    if (-not (Test-AgentLocalCiRunId $RunId)) { Throw-AgentLocalCi -Message "Invalid run identity" -ExitCode 4 }
    $run = Assert-AgentLocalCiOwnedPath (Join-Path $Context.RunsRoot $RunId) $Context.RunsRoot
    $scratch = Assert-AgentLocalCiOwnedPath (Join-Path $Context.ScratchRoot $RunId) $Context.ScratchRoot
    if ((Test-Path -LiteralPath $run) -or (Test-Path -LiteralPath $scratch)) { Throw-AgentLocalCi -Message "Run identity collision" -ExitCode 4 }
    [IO.Directory]::CreateDirectory($run) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $run "logs")) | Out-Null
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    return [pscustomobject]@{ Run = $run; Logs = (Join-Path $run "logs"); Scratch = $scratch; State = (Join-Path $run "state.json"); Report = (Join-Path $run "report.json"); Summary = (Join-Path $run "summary.md") }
}

function Write-AgentLocalCiRunState {
    param(
        [Parameter(Mandatory = $true)][object]$Directories,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Sha,
        [Parameter(Mandatory = $true)][string]$Profile,
        [AllowNull()][string]$Message,
        [AllowNull()][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources
    )
    $process = Get-Process -Id $PID
    $resourceRecords = @()
    if ($null -ne $Resources) {
        $resourceRecords = @($Resources.ToArray() | ForEach-Object {
            [ordered]@{
                type = ConvertTo-AgentLocalCiSafeDisplayText ([string]$_.Type) 32
                name = ConvertTo-AgentLocalCiSafeDisplayText ([string]$_.Name) 128
                kind = ConvertTo-AgentLocalCiSafeDisplayText ([string]$_.Kind) 128
                run_id = ConvertTo-AgentLocalCiSafeDisplayText ([string]$_.RunId) 64
            }
        })
    }
    $state = [ordered]@{
        schema_version = 1
        run_id = $RunId
        status = $Status
        target_sha = $Sha
        profile = $Profile
        controller_process_id = $PID
        controller_process_started_utc = $process.StartTime.ToUniversalTime().ToString("o")
        updated_utc = [DateTime]::UtcNow.ToString("o")
        message = ConvertTo-AgentLocalCiRedactedText $Message
        docker_resources = $resourceRecords
    }
    Write-AgentLocalCiJsonAtomic $Directories.State $state
}

function ConvertTo-AgentLocalCiSafeDisplayText {
    param(
        [AllowNull()][string]$Text,
        [ValidateRange(1, 4000)][int]$MaximumLength = 1000
    )
    if ($null -eq $Text) { return "" }
    $safe = ConvertTo-AgentLocalCiRedactedText $Text
    $safe = $safe -replace '[\r\n\t]+', ' '
    if ($safe.Length -gt $MaximumLength) { $safe = $safe.Substring(0, $MaximumLength) + "…" }
    return $safe
}

function Write-AgentLocalCiReport {
    param(
        [Parameter(Mandatory = $true)][object]$Directories,
        [Parameter(Mandatory = $true)][object]$Report
    )
    Write-AgentLocalCiJsonAtomic $Directories.Report $Report
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# AgentLocalCI report")
    $lines.Add("")
    $lines.Add("- Run: ``$($Report.run_id)``")
    $lines.Add("- Result: **$($Report.result)**")
    $lines.Add("- Target: ``$($Report.target_sha)``")
    $lines.Add("- Profile: ``$($Report.profile.name)``")
    $lines.Add("- Execution: $($Report.security.execution_boundary), validation network ``none``")
    $lines.Add("- Exact-tree source: $($Report.security.exact_tree_source)")
    $lines.Add("- Cleanup: $($Report.cleanup.status)")
    $lines.Add("")
    $lines.Add("## Stages")
    $lines.Add("")
    foreach ($stage in @($Report.stages)) { $lines.Add("- ``$($stage.id)`` — **$($stage.status)** ($($stage.duration_seconds)s, exit $($stage.exit_code))") }
    if (@($Report.profile.gaps).Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Declared gaps")
        $lines.Add("")
        foreach ($gap in @($Report.profile.gaps)) { $lines.Add("- " + (ConvertTo-AgentLocalCiSafeDisplayText $gap 1000)) }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.error)) {
        $lines.Add("")
        $lines.Add("## Controller error")
        $lines.Add("")
        $lines.Add((ConvertTo-AgentLocalCiSafeDisplayText $Report.error 2000))
    }
    [IO.File]::WriteAllLines($Directories.Summary, $lines, [Text.UTF8Encoding]::new($false))
}

function Get-AgentLocalCiRunReport {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [AllowNull()][string]$RunId
    )
    $resolved = $RunId
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $candidate = Get-ChildItem -LiteralPath $Context.RunsRoot -Directory | Sort-Object Name -Descending | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "report.json") -PathType Leaf } | Select-Object -First 1
        if ($null -eq $candidate) { Throw-AgentLocalCi -Message "No completed AgentLocalCI report exists" -ExitCode 2 }
        $resolved = $candidate.Name
    }
    if (-not (Test-AgentLocalCiRunId $resolved)) { Throw-AgentLocalCi -Message "Invalid report run identity" -ExitCode 2 }
    $directory = Assert-AgentLocalCiOwnedPath (Join-Path $Context.RunsRoot $resolved) $Context.RunsRoot
    $path = Join-Path $directory "report.json"
    $report = Read-AgentLocalCiJsonFile $path
    if ($null -eq $report -or [string]$report.run_id -cne $resolved) { Throw-AgentLocalCi -Message "Report is missing or invalid: $resolved" -ExitCode 2 }
    return [pscustomobject]@{ RunId = $resolved; Directory = $directory; Path = $path; Report = $report; Summary = (Join-Path $directory "summary.md") }
}

function Get-AgentLocalCiStatusRecords {
    param([Parameter(Mandatory = $true)][object]$Context)
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($directory in @(Get-ChildItem -LiteralPath $Context.RunsRoot -Directory | Sort-Object Name -Descending | Select-Object -First 20)) {
        if (-not (Test-AgentLocalCiRunId $directory.Name)) { continue }
        $state = Read-AgentLocalCiJsonFile (Join-Path $directory.FullName "state.json")
        $report = Read-AgentLocalCiJsonFile (Join-Path $directory.FullName "report.json")
        if ($null -ne $report) {
            $records.Add([pscustomobject]@{ run_id = $directory.Name; status = [string]$report.result; target_sha = [string]$report.target_sha; profile = [string]$report.profile.name; updated_utc = [string]$report.finished_utc; stale = $false })
        }
        elseif ($null -ne $state) {
            $alive = Test-AgentLocalCiProcessIdentityAlive ([int]$state.controller_process_id) ([string]$state.controller_process_started_utc)
            $records.Add([pscustomobject]@{ run_id = $directory.Name; status = if ($alive) { [string]$state.status } else { "Stale" }; target_sha = [string]$state.target_sha; profile = [string]$state.profile; updated_utc = [string]$state.updated_utc; stale = -not $alive })
        }
    }
    return $records.ToArray()
}

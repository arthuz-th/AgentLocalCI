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
    return [pscustomobject]@{
        Run = $run
        Logs = Join-Path $run "logs"
        Scratch = $scratch
        State = Join-Path $run "state.json"
        Report = Join-Path $run "report.json"
        Summary = Join-Path $run "summary.md"
        Html = Join-Path $run "report.html"
    }
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

function ConvertTo-AgentLocalCiHtmlText {
    param([AllowNull()][string]$Text)
    return [Net.WebUtility]::HtmlEncode((ConvertTo-AgentLocalCiSafeDisplayText $Text 4000))
}

function Get-AgentLocalCiResultExplanation {
    param([Parameter(Mandatory = $true)][string]$Result)
    $explanation = switch ($Result) {
        "Passed" { "Every configured acceptance stage passed and cleanup was proven complete." }
        "Failed" { "A project validation stage failed. Review the stage logs; the controller itself completed safely." }
        "InvalidConfiguration" { "The committed AgentLocalCI configuration or requested target was invalid." }
        "InfrastructureFailed" { "The trusted controller, Docker engine, or local toolchain could not complete the run." }
        "SafetyBlocked" { "AgentLocalCI stopped the run because a safety boundary could not be proven." }
        "CleanupFailed" { "The run finished, but cleanup could not be proven complete. Inspect retained resources before continuing." }
        "DiagnosticOnly" { "The configured profile completed, but it was explicitly marked as diagnostic rather than acceptance evidence." }
        "Cancelled" { "The run was interrupted before completion." }
        default { "See the JSON report for details." }
    }
    return $explanation
}

function Write-AgentLocalCiHtmlReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Report
    )
    $resultClass = if ([string]$Report.result -ceq "Passed") { "passed" } elseif ([string]$Report.result -ceq "DiagnosticOnly") { "warning" } else { "failed" }
    $stages = [Text.StringBuilder]::new()
    foreach ($stage in @($Report.stages)) {
        $stageClass = if ([string]$stage.status -ceq "Passed") { "passed" } elseif ([string]$stage.status -in @("DiagnosticOnly", "TimedOut", "OutputLimitExceeded")) { "warning" } else { "failed" }
        [void]$stages.AppendLine("<tr><td><code>$(ConvertTo-AgentLocalCiHtmlText ([string]$stage.id))</code></td><td><span class='badge $stageClass'>$(ConvertTo-AgentLocalCiHtmlText ([string]$stage.status))</span></td><td>$([double]$stage.duration_seconds)s</td><td>$([int]$stage.exit_code)</td><td><code>$(ConvertTo-AgentLocalCiHtmlText ([string]$stage.stdout_log))</code></td></tr>")
    }
    if (@($Report.stages).Count -eq 0) { [void]$stages.AppendLine("<tr><td colspan='5'>No validation stage completed.</td></tr>") }

    $gaps = [Text.StringBuilder]::new()
    foreach ($gap in @($Report.profile.gaps)) { [void]$gaps.AppendLine("<li>$(ConvertTo-AgentLocalCiHtmlText ([string]$gap))</li>") }
    if (@($Report.profile.gaps).Count -eq 0) { [void]$gaps.AppendLine("<li>None declared.</li>") }

    $errorBlock = ""
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.error)) {
        $errorBlock = "<section><h2>Controller message</h2><pre>$(ConvertTo-AgentLocalCiHtmlText ([string]$Report.error))</pre></section>"
    }
    $imageText = if ($null -eq $Report.image) { "not available" } else { "$(ConvertTo-AgentLocalCiHtmlText ([string]$Report.image.id)) ($(ConvertTo-AgentLocalCiHtmlText ([string]$Report.image.architecture)))" }
    $hostPlatform = if ($null -ne $Report.host) { [string]$Report.host.platform } else { "unknown" }
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AgentLocalCI $(ConvertTo-AgentLocalCiHtmlText ([string]$Report.result)) — $(ConvertTo-AgentLocalCiHtmlText ([string]$Report.project))</title>
<style>
:root{color-scheme:light dark;font-family:ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;line-height:1.5}body{max-width:1080px;margin:0 auto;padding:28px}header,section{border:1px solid #8885;border-radius:16px;padding:20px;margin:0 0 18px;background:#8881}h1,h2{margin-top:0}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}.card{border:1px solid #8884;border-radius:12px;padding:14px;background:#8881}.label{font-size:.82rem;opacity:.72}.value{font-weight:650;overflow-wrap:anywhere}.badge{display:inline-block;border-radius:999px;padding:4px 10px;font-weight:700}.passed{background:#16803b22;color:#25a754}.warning{background:#b7791f22;color:#d69e2e}.failed{background:#c5303022;color:#ef5350}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px;border-bottom:1px solid #8884;vertical-align:top}code,pre{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;overflow-wrap:anywhere}pre{white-space:pre-wrap;border:1px solid #8884;border-radius:10px;padding:12px}footer{opacity:.68;font-size:.9rem;margin-top:24px}@media(max-width:700px){body{padding:14px}table{display:block;overflow-x:auto}}
</style>
</head>
<body>
<header>
<p class="label">AgentLocalCI exact-commit report</p>
<h1><span class="badge $resultClass">$(ConvertTo-AgentLocalCiHtmlText ([string]$Report.result))</span> $(ConvertTo-AgentLocalCiHtmlText ([string]$Report.project))</h1>
<p>$(ConvertTo-AgentLocalCiHtmlText (Get-AgentLocalCiResultExplanation ([string]$Report.result)))</p>
<div class="grid">
<div class="card"><div class="label">Target commit</div><div class="value"><code>$(ConvertTo-AgentLocalCiHtmlText ([string]$Report.target_sha))</code></div></div>
<div class="card"><div class="label">Profile</div><div class="value">$(ConvertTo-AgentLocalCiHtmlText ([string]$Report.profile.name))</div></div>
<div class="card"><div class="label">Host</div><div class="value">$(ConvertTo-AgentLocalCiHtmlText $hostPlatform)</div></div>
<div class="card"><div class="label">Duration</div><div class="value">$([double]$Report.duration_seconds)s</div></div>
</div>
</header>
<section><h2>Stages</h2><table><thead><tr><th>Stage</th><th>Status</th><th>Duration</th><th>Exit</th><th>Sanitized log</th></tr></thead><tbody>$stages</tbody></table></section>
<section><h2>Safety evidence</h2><div class="grid">
<div class="card"><div class="label">Validation network</div><div class="value"><code>$(ConvertTo-AgentLocalCiHtmlText ([string]$Report.security.validation_network))</code></div></div>
<div class="card"><div class="label">Exact-tree source</div><div class="value">$([bool]$Report.security.exact_tree_source)</div></div>
<div class="card"><div class="label">Host mounts</div><div class="value">$([bool]$Report.security.host_mounts)</div></div>
<div class="card"><div class="label">Credentials forwarded</div><div class="value">$([bool]$Report.security.credentials_forwarded)</div></div>
<div class="card"><div class="label">Cleanup</div><div class="value">$(ConvertTo-AgentLocalCiHtmlText ([string]$Report.cleanup.status))</div></div>
<div class="card"><div class="label">Trusted image</div><div class="value"><code>$imageText</code></div></div>
</div></section>
<section><h2>Declared gaps</h2><ul>$gaps</ul></section>
$errorBlock
<footer>Run <code>$(ConvertTo-AgentLocalCiHtmlText ([string]$Report.run_id))</code>. This self-contained file has no external scripts, fonts, images, or network requests. The JSON report remains the machine-readable source of truth.</footer>
</body>
</html>
"@
    [IO.File]::WriteAllText($Path, $html, [Text.UTF8Encoding]::new($false))
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
    if ($null -ne $Report.host) { $lines.Add("- Host: ``$($Report.host.platform)`` / ``$($Report.host.architecture)``") }
    $lines.Add("- Execution: $($Report.security.execution_boundary), validation network ``none``")
    $lines.Add("- Exact-tree source: $($Report.security.exact_tree_source)")
    $lines.Add("- Cleanup: $($Report.cleanup.status)")
    $lines.Add("")
    $lines.Add((Get-AgentLocalCiResultExplanation ([string]$Report.result)))
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
    Write-AgentLocalCiHtmlReport $Directories.Html $Report
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
    $html = Join-Path $directory "report.html"
    if (-not (Test-Path -LiteralPath $html -PathType Leaf)) { Write-AgentLocalCiHtmlReport $html $report }
    return [pscustomobject]@{ RunId = $resolved; Directory = $directory; Path = $path; Report = $report; Summary = (Join-Path $directory "summary.md"); Html = $html }
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

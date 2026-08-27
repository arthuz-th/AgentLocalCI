[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$cliPath = Join-Path $repoRoot "bin\agentlocalci.ps1"
$testHome = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-integration-" + [Guid]::NewGuid().ToString("N"))
$createdVolumes = [Collections.Generic.List[string]]::new()
$passed = 0
$failed = 0
$failures = [Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-DockerCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $output = @(& docker.exe @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) { throw "docker $($Arguments -join ' ') failed with exit $exitCode" }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Invoke-Clean {
    $output = @(& pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cliPath clean --wait-seconds 1 --home $testHome --repository $repoRoot 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function New-TestRunId {
    return ([DateTime]::UtcNow.ToString("yyyyMMdd-HHmmssfff") + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 12))
}

function New-StaleRunState {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$VolumeName,
        [Parameter(Mandatory = $true)][string]$RecordedKind
    )
    $runDirectory = Join-Path $testHome "runtime\runs\$RunId"
    [IO.Directory]::CreateDirectory($runDirectory) | Out-Null
    $state = [ordered]@{
        schema_version = 1
        run_id = $RunId
        status = "Running"
        target_sha = "0000000000000000000000000000000000000000"
        profile = "integration"
        controller_process_id = 2147483000
        controller_process_started_utc = "2000-01-01T00:00:00.0000000Z"
        updated_utc = [DateTime]::UtcNow.ToString("o")
        message = "fault-injection fixture"
        docker_resources = @(
            [ordered]@{ type = "volume"; name = $VolumeName; kind = $RecordedKind; run_id = $RunId }
        )
    }
    [IO.File]::WriteAllText((Join-Path $runDirectory "state.json"), ($state | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:passed++
        Write-Output "PASS $Name"
    }
    catch {
        $script:failed++
        $script:failures.Add("$Name`: $($_.Exception.Message)")
        Write-Output "FAIL $Name"
    }
}

try {
    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) { throw "docker.exe is required" }
    [IO.Directory]::CreateDirectory($testHome) | Out-Null

    $unrelatedVolume = "alc-integration-unrelated-" + [Guid]::NewGuid().ToString("N").Substring(0, 12)
    Invoke-DockerCommand @("volume", "create", $unrelatedVolume) | Out-Null
    $createdVolumes.Add($unrelatedVolume)

    Test-Case "clean repairs a dead run and deletes only its exact owned volume" {
        $runId = New-TestRunId
        $volume = "alc-" + $runId.Substring($runId.Length - 12) + "-fault"
        Invoke-DockerCommand @(
            "volume", "create",
            "--label", "io.agentlocalci.owner=agentlocalci",
            "--label", "io.agentlocalci.run=$runId",
            "--label", "io.agentlocalci.kind=fault-volume",
            $volume
        ) | Out-Null
        $createdVolumes.Add($volume)
        New-StaleRunState $runId $volume "fault-volume"

        $result = Invoke-Clean
        Assert-True ($result.ExitCode -eq 0) ("clean exit was $($result.ExitCode): " + ($result.Output -join " "))
        Assert-True ((Invoke-DockerCommand @("volume", "inspect", $volume) -AllowFailure).ExitCode -ne 0) "exact owned volume still exists"
        Assert-True ((Invoke-DockerCommand @("volume", "inspect", $unrelatedVolume) -AllowFailure).ExitCode -eq 0) "unrelated volume was deleted"
        $state = Get-Content -LiteralPath (Join-Path $testHome "runtime\runs\$runId\state.json") -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        Assert-True ([string]$state.status -ceq "AbandonedRecovered") "stale run state was not marked recovered"
    }

    Test-Case "clean refuses an ownership-kind mismatch and retains the resource" {
        $runId = New-TestRunId
        $volume = "alc-" + $runId.Substring($runId.Length - 12) + "-mismatch"
        Invoke-DockerCommand @(
            "volume", "create",
            "--label", "io.agentlocalci.owner=agentlocalci",
            "--label", "io.agentlocalci.run=$runId",
            "--label", "io.agentlocalci.kind=actual-kind",
            $volume
        ) | Out-Null
        $createdVolumes.Add($volume)
        New-StaleRunState $runId $volume "recorded-kind"

        $result = Invoke-Clean
        Assert-True ($result.ExitCode -eq 5) ("mismatch clean exit was $($result.ExitCode): " + ($result.Output -join " "))
        Assert-True ((Invoke-DockerCommand @("volume", "inspect", $volume) -AllowFailure).ExitCode -eq 0) "mismatched resource was deleted"
        Invoke-DockerCommand @("volume", "rm", $volume) | Out-Null
    }

    Test-Case "clean retains an owner-labeled resource with no run state" {
        $runId = New-TestRunId
        $volume = "alc-" + $runId.Substring($runId.Length - 12) + "-orphan"
        Invoke-DockerCommand @(
            "volume", "create",
            "--label", "io.agentlocalci.owner=agentlocalci",
            "--label", "io.agentlocalci.run=$runId",
            "--label", "io.agentlocalci.kind=orphan-volume",
            $volume
        ) | Out-Null
        $createdVolumes.Add($volume)

        $result = Invoke-Clean
        Assert-True ($result.ExitCode -eq 5) ("orphan clean exit was $($result.ExitCode): " + ($result.Output -join " "))
        Assert-True ((Invoke-DockerCommand @("volume", "inspect", $volume) -AllowFailure).ExitCode -eq 0) "unclaimed owner-labeled resource was deleted"
        Invoke-DockerCommand @("volume", "rm", $volume) | Out-Null
    }
}
finally {
    foreach ($volume in $createdVolumes) { Invoke-DockerCommand @("volume", "rm", "--force", $volume) -AllowFailure | Out-Null }
    if (Test-Path -LiteralPath $testHome) { Remove-Item -LiteralPath $testHome -Recurse -Force }
}

Write-Output "RESULT passed=$passed failed=$failed"
if ($failed -gt 0) {
    foreach ($failure in $failures) { [Console]::Error.WriteLine($failure) }
    exit 1
}
exit 0

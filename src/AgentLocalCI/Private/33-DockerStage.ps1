function Merge-AgentLocalCiEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Global,
        [Parameter(Mandatory = $true)][object]$Stage
    )
    $result = [ordered]@{}
    foreach ($property in $Global.PSObject.Properties) { $result[$property.Name] = [string]$property.Value }
    foreach ($property in $Stage.PSObject.Properties) { $result[$property.Name] = [string]$property.Value }
    return [pscustomobject]$result
}

function Get-AgentLocalCiStageStatus {
    param([Parameter(Mandatory = $true)][object]$Execution)
    if ([int]$Execution.ExitCode -eq 0) { return "Passed" }
    if ([bool]$Execution.TimedOut) { return "TimedOut" }
    if ([bool]$Execution.OutputLimitExceeded) { return "OutputLimitExceeded" }
    if ([int]$Execution.ExitCode -ge 200 -and [int]$Execution.ExitCode -le 209) { return "SafetyBlocked" }
    if ([int]$Execution.ExitCode -ge 210 -and [int]$Execution.ExitCode -le 219) { return "InfrastructureFailed" }
    return "Failed"
}

function Invoke-AgentLocalCiStage {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Image,
        [Parameter(Mandatory = $true)][object]$Pipeline,
        [Parameter(Mandatory = $true)][object]$Stage,
        [Parameter(Mandatory = $true)][object]$Provenance,
        [Parameter(Mandatory = $true)][object]$DependencySeeds,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$NamePrefix,
        [Parameter(Mandatory = $true)][int]$StageIndex,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources,
        [Parameter(Mandatory = $true)][string]$LogDirectory
    )
    $started = [DateTime]::UtcNow
    $stagePrefix = "$NamePrefix-s$($StageIndex.ToString('00'))"
    $source = New-AgentLocalCiSourceVolumeFromPack $Context $Image $Provenance $RunId $stagePrefix $Resources $LogDirectory
    $evidence = "$stagePrefix-evidence"
    New-AgentLocalCiDockerVolume $evidence $RunId "stage-evidence" $Resources | Out-Null
    $mounts = New-Object System.Collections.Generic.List[string]
    $volumes = New-Object System.Collections.Generic.List[string]
    $mounts.Add("type=volume,source=$source,target=/workspace")
    $mounts.Add("type=volume,source=$evidence,target=/evidence")
    $volumes.Add($source)
    $volumes.Add($evidence)

    if (@($Stage.needs) -contains "npm") {
        if ([string]::IsNullOrWhiteSpace([string]$DependencySeeds.npm)) { Throw-AgentLocalCi -Message "npm seed is unavailable for stage '$($Stage.id)'" -ExitCode 3 }
        $npm = "$stagePrefix-npm"
        New-AgentLocalCiDockerVolume $npm $RunId "stage-npm-cache" $Resources | Out-Null
        Copy-AgentLocalCiVolume $Context $Image $DependencySeeds.npm $npm $RunId "$stagePrefix-npm" $Resources $LogDirectory
        $mounts.Add("type=volume,source=$npm,target=/npm-cache")
        $volumes.Add($npm)
    }
    if (@($Stage.needs) -contains "gradle") {
        if ([string]::IsNullOrWhiteSpace([string]$DependencySeeds.gradle)) { Throw-AgentLocalCi -Message "Gradle seed is unavailable for stage '$($Stage.id)'" -ExitCode 3 }
        $gradle = "$stagePrefix-gradle"
        New-AgentLocalCiDockerVolume $gradle $RunId "stage-gradle-cache" $Resources | Out-Null
        Copy-AgentLocalCiVolume $Context $Image $DependencySeeds.gradle $gradle $RunId "$stagePrefix-gradle" $Resources $LogDirectory
        $mounts.Add("type=volume,source=$gradle,target=/gradle")
        $volumes.Add($gradle)
    }

    $job = [ordered]@{
        sha = $Provenance.Commit
        tree = $Provenance.Tree
        stage_id = [string]$Stage.id
        command = @($Stage.command)
        working_directory = [string]$Stage.working_directory
        needs = @($Stage.needs)
        environment = Merge-AgentLocalCiEnvironment $Pipeline.environment $Stage.environment
        dependencies = $Pipeline.dependencies
        gradle_max_workers = [int]$Context.Policy.resources.gradle_max_workers
    }
    $jobJson = $job | ConvertTo-Json -Depth 50 -Compress
    $jobBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jobJson))
    $container = "$stagePrefix-run"
    $arguments = New-AgentLocalCiContainerBaseArguments $Context $container $RunId "stage-$($Stage.id)" "none"
    foreach ($mount in $mounts) { $arguments += @("--mount", $mount) }
    $arguments += @(
        "--workdir", "/workspace/repo",
        "--env", "AGENTLOCALCI_TARGET_SHA=$($Provenance.Commit)",
        "--env", "AGENTLOCALCI_TARGET_TREE=$($Provenance.Tree)",
        $Image.Id, "pwsh", "-NoLogo", "-NoProfile", "-NonInteractive",
        "-File", "/opt/agentlocalci/runner.ps1", "-JobBase64", $jobBase64
    )
    New-AgentLocalCiTrackedContainer $arguments $container $RunId "stage-$($Stage.id)" $Resources | Out-Null
    Assert-AgentLocalCiRuntimeContainer $container $Image.Id $volumes.ToArray() "none"
    $stdoutPath = Join-Path $LogDirectory "$($StageIndex.ToString('00'))-$($Stage.id).stdout.log"
    $stderrPath = Join-Path $LogDirectory "$($StageIndex.ToString('00'))-$($Stage.id).stderr.log"
    $execution = Start-AgentLocalCiContainerWithTimeout $container $stdoutPath $stderrPath ([int]$Stage.timeout_seconds) ([int]$Context.Policy.resources.output_limit_mib)
    $finished = [DateTime]::UtcNow
    return [pscustomobject]@{
        id = [string]$Stage.id
        index = $StageIndex
        status = Get-AgentLocalCiStageStatus $execution
        exit_code = [int]$execution.ExitCode
        timed_out = [bool]$execution.TimedOut
        output_limit_exceeded = [bool]$execution.OutputLimitExceeded
        started_utc = $started.ToString("o")
        finished_utc = $finished.ToString("o")
        duration_seconds = [Math]::Round(($finished - $started).TotalSeconds, 3)
        stdout_log = [IO.Path]::GetFileName($stdoutPath)
        stderr_log = [IO.Path]::GetFileName($stderrPath)
        execution_boundary = $script:AgentLocalCiBoundaryMarker
        network = "none"
        exact_source = $true
    }
}

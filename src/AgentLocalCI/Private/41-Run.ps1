function Invoke-AgentLocalCiRun {
    param(
        [AllowNull()][string]$Home,
        [AllowNull()][string]$RepositoryRoot,
        [AllowNull()][string]$PolicyPath,
        [Parameter(Mandatory = $true)][string]$Sha,
        [AllowNull()][string]$ProfileName,
        [ValidateRange(0, 86400)][int]$WaitSeconds = 0
    )
    $context = Get-AgentLocalCiContext $Home $RepositoryRoot $PolicyPath
    if (-not [bool]$context.Policy.enabled) { Throw-AgentLocalCi -Message "AgentLocalCI is disabled by machine policy" -ExitCode 4 }
    $target = Resolve-AgentLocalCiCommit $context.RepositoryRoot $Sha
    $pipeline = Read-AgentLocalCiPipelineFromCommit $context $target
    $profile = Get-AgentLocalCiProfile $pipeline $ProfileName
    $runId = New-AgentLocalCiRunId
    $lock = New-AgentLocalCiControllerLock $context $runId $WaitSeconds
    $directories = $null
    $resources = [Collections.Generic.List[object]]::new()
    $stages = [Collections.Generic.List[object]]::new()
    $started = [DateTime]::UtcNow
    $resultName = "InfrastructureFailed"
    $exitCode = 3
    $errorText = ""
    $image = $null
    $provenance = $null
    $cleanup = [pscustomobject]@{ Passed = $false; Failures = @("cleanup not reached") }
    try {
        $directories = New-AgentLocalCiRunDirectories $context $runId
        Write-AgentLocalCiRunState $directories $runId "Running" $target $profile.name "initializing trusted controller" $resources
        $image = Get-AgentLocalCiTrustedImage $context
        Write-AgentLocalCiRunState $directories $runId "Running" $target $profile.name "creating exact-tree provenance pack" $resources
        $provenance = New-AgentLocalCiProvenancePack $context $target $directories.Scratch
        $namePrefix = Get-AgentLocalCiDockerPrefix $runId
        Write-AgentLocalCiRunState $directories $runId "Running" $target $profile.name "preparing policy-approved dependency caches" $resources
        $seeds = Initialize-AgentLocalCiDependencySeeds $context $image $pipeline $profile $provenance $runId $namePrefix $resources $directories.Logs
        Write-AgentLocalCiRunState $directories $runId "Running" $target $profile.name "dependency cache preparation completed" $resources
        $index = 0
        foreach ($stage in @($profile.stages)) {
            $index++
            Write-AgentLocalCiRunState $directories $runId "Running" $target $profile.name "running stage $index of $(@($profile.stages).Count): $($stage.id)" $resources
            $stageResult = Invoke-AgentLocalCiStage $context $image $pipeline $stage $provenance $seeds $runId $namePrefix $index $resources $directories.Logs
            $stages.Add($stageResult)
            Write-AgentLocalCiRunState $directories $runId "Running" $target $profile.name "stage $($stage.id) completed with status $($stageResult.status)" $resources
            if ($stageResult.exit_code -ne 0) {
                switch ([string]$stageResult.status) {
                    "SafetyBlocked" { $resultName = "SafetyBlocked"; $exitCode = 4 }
                    "InfrastructureFailed" { $resultName = "InfrastructureFailed"; $exitCode = 3 }
                    default { $resultName = "Failed"; $exitCode = 1 }
                }
                break
            }
        }
        $allStagesPassed = $stages.Count -eq @($profile.stages).Count -and @($stages.ToArray() | Where-Object { [int]$_.exit_code -ne 0 }).Count -eq 0
        if ($allStagesPassed) {
            if ([bool]$profile.acceptance) { $resultName = "Passed"; $exitCode = 0 }
            else { $resultName = "DiagnosticOnly"; $exitCode = 6 }
        }
    }
    catch [Management.Automation.PipelineStoppedException] {
        $resultName = "Cancelled"
        $exitCode = 130
        $errorText = "AgentLocalCI was interrupted"
    }
    catch {
        $exitCode = Get-AgentLocalCiExceptionExitCode $_.Exception
        $resultName = switch ($exitCode) {
            1 { "Failed" }
            2 { "InvalidConfiguration" }
            3 { "InfrastructureFailed" }
            4 { "SafetyBlocked" }
            5 { "CleanupFailed" }
            6 { "DiagnosticOnly" }
            130 { "Cancelled" }
            default { "InfrastructureFailed" }
        }
        $errorText = ConvertTo-AgentLocalCiRedactedText $_.Exception.Message
    }
    finally {
        try { $cleanup = Remove-AgentLocalCiResources $resources }
        catch { $cleanup = [pscustomobject]@{ Passed = $false; Failures = @((ConvertTo-AgentLocalCiRedactedText $_.Exception.Message)) } }
        if ($null -ne $directories) {
            try {
                if (Test-Path -LiteralPath $directories.Scratch) {
                    $scratch = Assert-AgentLocalCiOwnedPath $directories.Scratch $context.ScratchRoot
                    Remove-Item -LiteralPath $scratch -Recurse -Force
                }
            }
            catch {
                $cleanup = [pscustomobject]@{ Passed = $false; Failures = @($cleanup.Failures) + @("private scratch cleanup failed: " + (ConvertTo-AgentLocalCiRedactedText $_.Exception.Message)) }
            }
        }
        if (-not $cleanup.Passed) {
            $resultName = "CleanupFailed"
            $exitCode = 5
        }
        if ($null -ne $lock) { $lock.Dispose() }
    }

    $finished = [DateTime]::UtcNow
    if ($null -eq $directories) { Throw-AgentLocalCi -Message $(if ($errorText) { $errorText } else { "AgentLocalCI could not create a run report" }) -ExitCode $exitCode }
    $report = [ordered]@{
        schema_version = 1
        tool = [ordered]@{ name = "AgentLocalCI"; version = $script:AgentLocalCiVersion; controller_identity = if ($null -ne $image) { $image.Identity } else { Get-AgentLocalCiControllerIdentity $context } }
        host = [ordered]@{
            platform = Get-AgentLocalCiHostPlatform
            architecture = Get-AgentLocalCiHostArchitecture
            powershell = $PSVersionTable.PSVersion.ToString()
        }
        run_id = $runId
        project = ConvertTo-AgentLocalCiSafeDisplayText ([string]$pipeline.project.name) 80
        target_sha = $target
        target_tree = if ($null -ne $provenance) { [string]$provenance.Tree } else { "" }
        profile = [ordered]@{
            name = [string]$profile.name
            acceptance = [bool]$profile.acceptance
            description = ConvertTo-AgentLocalCiSafeDisplayText ([string]$profile.description) 500
            gaps = @($profile.gaps | ForEach-Object { ConvertTo-AgentLocalCiSafeDisplayText ([string]$_) 1000 })
        }
        result = $resultName
        exit_code = $exitCode
        started_utc = $started.ToString("o")
        finished_utc = $finished.ToString("o")
        duration_seconds = [Math]::Round(($finished - $started).TotalSeconds, 3)
        stages = $stages.ToArray()
        provenance = [ordered]@{
            exact_commit = $target
            exact_tree = if ($null -ne $provenance) { [string]$provenance.Tree } else { "" }
            object_count = if ($null -ne $provenance) { [int]$provenance.ObjectCount } else { 0 }
            pack_sha256 = if ($null -ne $provenance) { [string]$provenance.PackSha256 } else { "" }
            history_included = $false
            host_checkout_performed = $false
            remote_metadata_included = $false
        }
        fingerprints = [ordered]@{
            pipeline_sha256 = Get-AgentLocalCiStringSha256 ($pipeline | ConvertTo-Json -Depth 100 -Compress)
            policy_sha256 = Get-AgentLocalCiStringSha256 ($context.Policy | ConvertTo-Json -Depth 100 -Compress)
            repository_path_sha256 = Get-AgentLocalCiStringSha256 $context.RepositoryRoot.ToLowerInvariant()
        }
        image = if ($null -ne $image) { [ordered]@{ id = $image.Id; tag = $image.Tag; identity = $image.Identity; built_at = $image.BuiltAt; architecture = $image.Architecture; os = $image.Os } } else { $null }
        security = [ordered]@{
            execution_boundary = $script:AgentLocalCiBoundaryMarker
            exact_tree_source = $true
            git_metadata_in_validation_workspace = $false
            validation_network = "none"
            host_mounts = $false
            docker_socket = $false
            privileged = $false
            credentials_forwarded = $false
            shell_command_strings_from_pipeline = $false
            logs_redacted_before_persistence = $true
            target_artifacts_exported_to_host = $false
        }
        cleanup = [ordered]@{
            status = if ($cleanup.Passed) { "Passed" } else { "Failed" }
            resource_count = $resources.Count
            failures = @($cleanup.Failures | ForEach-Object { ConvertTo-AgentLocalCiSafeDisplayText ([string]$_) 1000 })
            private_scratch_removed = -not (Test-Path -LiteralPath $directories.Scratch)
        }
        error = ConvertTo-AgentLocalCiSafeDisplayText $errorText 2000
    }
    Write-AgentLocalCiReport $directories $report
    Write-AgentLocalCiRunState $directories $runId $resultName $target $profile.name "completed" $resources
    return [pscustomobject]@{ ExitCode = $exitCode; RunId = $runId; Result = $resultName; ReportPath = $directories.Report; SummaryPath = $directories.Summary; HtmlPath = $directories.Html; Report = [pscustomobject]$report }
}

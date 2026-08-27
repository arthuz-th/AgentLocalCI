function ConvertFrom-AgentLocalCiCliArguments {
    param([AllowEmptyCollection()][string[]]$Arguments)
    if ($Arguments.Count -eq 0) { return [pscustomobject]@{ Command = "help"; Options = @{}; Positionals = @() } }
    $command = $Arguments[0].ToLowerInvariant()
    $options = [ordered]@{}
    $positionals = New-Object System.Collections.Generic.List[string]
    $index = 1
    while ($index -lt $Arguments.Count) {
        $token = [string]$Arguments[$index]
        if ($token.StartsWith("--", [StringComparison]::Ordinal)) {
            $name = $token.Substring(2).ToLowerInvariant()
            if ($name -cnotmatch '^[a-z][a-z0-9-]*$' -or $options.Contains($name)) { Throw-AgentLocalCi -Message "Invalid or duplicate option '$token'" -ExitCode 2 }
            if ($index + 1 -lt $Arguments.Count -and -not ([string]$Arguments[$index + 1]).StartsWith("--", [StringComparison]::Ordinal)) {
                $options[$name] = [string]$Arguments[$index + 1]
                $index += 2
            }
            else {
                $options[$name] = $true
                $index++
            }
        }
        else {
            $positionals.Add($token)
            $index++
        }
    }
    return [pscustomobject]@{ Command = $command; Options = $options; Positionals = $positionals.ToArray() }
}

function Assert-AgentLocalCiCliOptions {
    param(
        [Parameter(Mandatory = $true)][object]$Parsed,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Allowed,
        [ValidateRange(0, 10)][int]$MaximumPositionals = 0
    )
    foreach ($name in $Parsed.Options.Keys) { if ($Allowed -cnotcontains $name) { Throw-AgentLocalCi -Message "Option '--$name' is not valid for '$($Parsed.Command)'" -ExitCode 2 } }
    if ($Parsed.Positionals.Count -gt $MaximumPositionals) { Throw-AgentLocalCi -Message "Too many positional arguments for '$($Parsed.Command)'" -ExitCode 2 }
}

function Get-AgentLocalCiCliStringOption {
    param(
        [Parameter(Mandatory = $true)][object]$Parsed,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Required
    )
    if (-not $Parsed.Options.Contains($Name)) {
        if ($Required) { Throw-AgentLocalCi -Message "Missing required option '--$Name'" -ExitCode 2 }
        return $null
    }
    $value = $Parsed.Options[$Name]
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) { Throw-AgentLocalCi -Message "Option '--$Name' requires a value" -ExitCode 2 }
    return [string]$value
}

function Get-AgentLocalCiCliIntOption {
    param(
        [Parameter(Mandatory = $true)][object]$Parsed,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Default = 0,
        [int]$Minimum = 0,
        [int]$Maximum = 86400
    )
    if (-not $Parsed.Options.Contains($Name)) { return $Default }
    $raw = Get-AgentLocalCiCliStringOption $Parsed $Name -Required
    $value = 0
    if (-not [int]::TryParse($raw, [ref]$value) -or $value -lt $Minimum -or $value -gt $Maximum) { Throw-AgentLocalCi -Message "Option '--$Name' must be an integer in $Minimum..$Maximum" -ExitCode 2 }
    return $value
}

function Test-AgentLocalCiCliFlag {
    param([Parameter(Mandatory = $true)][object]$Parsed, [Parameter(Mandatory = $true)][string]$Name)
    if (-not $Parsed.Options.Contains($Name)) { return $false }
    if ($Parsed.Options[$Name] -isnot [bool]) { Throw-AgentLocalCi -Message "Option '--$Name' is a flag and takes no value" -ExitCode 2 }
    return $true
}

function Get-AgentLocalCiHelpText {
    return @"
AgentLocalCI $script:AgentLocalCiVersion

Usage:
  agentlocalci doctor [--build-image] [--home PATH]
  agentlocalci init [--repository PATH]
  agentlocalci validate-config --sha COMMIT [--repository PATH]
  agentlocalci profiles --sha COMMIT [--repository PATH]
  agentlocalci run --sha COMMIT [--profile NAME] [--wait-seconds N] [--repository PATH]
  agentlocalci status [--home PATH]
  agentlocalci report [RUN_ID] [--json] [--home PATH]
  agentlocalci clean [--images] [--wait-seconds N] [--home PATH]
  agentlocalci service <start|stop|restart|status> [--home PATH]
  agentlocalci uninstall [--home PATH]
  agentlocalci version

The run command accepts only an exact lowercase 40-character local commit SHA. It does not fetch,
forward credentials, mount the host repository, or run validation with network access.
"@
}

function Invoke-AgentLocalCiCli {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Arguments)
    try {
        $parsed = ConvertFrom-AgentLocalCiCliArguments $Arguments
        $global = @("home", "repository", "policy")
        $home = if ($parsed.Options.Contains("home")) { Get-AgentLocalCiCliStringOption $parsed "home" -Required } else { $null }
        $repository = if ($parsed.Options.Contains("repository")) { Get-AgentLocalCiCliStringOption $parsed "repository" -Required } else { $null }
        $policy = if ($parsed.Options.Contains("policy")) { Get-AgentLocalCiCliStringOption $parsed "policy" -Required } else { $null }
        switch ($parsed.Command) {
            { $_ -in @("help", "-h", "--help") } {
                Assert-AgentLocalCiCliOptions $parsed @() 0
                Get-AgentLocalCiHelpText
                return 0
            }
            "version" {
                Assert-AgentLocalCiCliOptions $parsed @() 0
                "AgentLocalCI $script:AgentLocalCiVersion (schema $script:AgentLocalCiSchemaVersion)"
                return 0
            }
            "doctor" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("build-image")) 0
                $doctor = Invoke-AgentLocalCiDoctor $home $repository $policy -BuildImage:(Test-AgentLocalCiCliFlag $parsed "build-image")
                foreach ($check in @($doctor.Checks)) { "[{0}] {1}: {2}" -f $(if ($check.passed) { "PASS" } else { "FAIL" }), $check.name, $check.detail }
                return $(if ($doctor.Passed) { 0 } else { 3 })
            }
            "init" {
                Assert-AgentLocalCiCliOptions $parsed $global 0
                $result = Initialize-AgentLocalCiRepository $home $repository $policy
                $result | ConvertTo-Json -Depth 10
                return 0
            }
            "validate-config" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("sha")) 0
                $sha = Get-AgentLocalCiCliStringOption $parsed "sha" -Required
                $context = Get-AgentLocalCiContext $home $repository $policy
                $target = Resolve-AgentLocalCiCommit $context.RepositoryRoot $sha
                $pipeline = Read-AgentLocalCiPipelineFromCommit $context $target
                [pscustomobject]@{ valid = $true; target_sha = $target; project = $pipeline.project.name; default_profile = $pipeline.default_profile; profiles = @($pipeline.profiles.PSObject.Properties.Name) } | ConvertTo-Json -Depth 20
                return 0
            }
            "profiles" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("sha")) 0
                $sha = Get-AgentLocalCiCliStringOption $parsed "sha" -Required
                $context = Get-AgentLocalCiContext $home $repository $policy
                $pipeline = Read-AgentLocalCiPipelineFromCommit $context (Resolve-AgentLocalCiCommit $context.RepositoryRoot $sha)
                foreach ($property in $pipeline.profiles.PSObject.Properties) {
                    $profile = $property.Value
                    "{0}: acceptance={1}; stages={2}; gaps={3}; {4}" -f $property.Name, $profile.acceptance, @($profile.stages).Count, @($profile.gaps).Count, $profile.description
                }
                return 0
            }
            "run" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("sha", "profile", "wait-seconds")) 0
                $sha = Get-AgentLocalCiCliStringOption $parsed "sha" -Required
                $profileName = if ($parsed.Options.Contains("profile")) { Get-AgentLocalCiCliStringOption $parsed "profile" -Required } else { $null }
                $wait = Get-AgentLocalCiCliIntOption $parsed "wait-seconds" 0 0 86400
                $run = Invoke-AgentLocalCiRun $home $repository $policy $sha $profileName $wait
                "Run $($run.RunId): $($run.Result)"
                "Report: $($run.ReportPath)"
                return [int]$run.ExitCode
            }
            "status" {
                Assert-AgentLocalCiCliOptions $parsed $global 0
                $context = Get-AgentLocalCiContext $home $repository $policy -RepositoryOptional
                $records = Get-AgentLocalCiStatusRecords $context
                if ($records.Count -eq 0) { "No AgentLocalCI runs found." }
                else { foreach ($record in $records) { "{0}  {1,-20} {2}  {3}" -f $record.run_id, $record.status, $record.target_sha, $record.profile } }
                return 0
            }
            "report" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("json")) 1
                $context = Get-AgentLocalCiContext $home $repository $policy -RepositoryOptional
                $runId = if ($parsed.Positionals.Count -eq 1) { [string]$parsed.Positionals[0] } else { $null }
                $report = Get-AgentLocalCiRunReport $context $runId
                if (Test-AgentLocalCiCliFlag $parsed "json") { Get-Content -LiteralPath $report.Path -Raw -Encoding UTF8 }
                else { Get-Content -LiteralPath $report.Summary -Raw -Encoding UTF8 }
                return 0
            }
            "clean" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("images", "wait-seconds")) 0
                $wait = Get-AgentLocalCiCliIntOption $parsed "wait-seconds" 0 0 86400
                $clean = Invoke-AgentLocalCiClean $home $repository $policy $wait -Images:(Test-AgentLocalCiCliFlag $parsed "images")
                $clean | ConvertTo-Json -Depth 20
                return $(if ($clean.Passed) { 0 } else { 5 })
            }
            "service" {
                Assert-AgentLocalCiCliOptions $parsed $global 1
                if ($parsed.Positionals.Count -ne 1) { Throw-AgentLocalCi -Message "service requires start, stop, restart, or status" -ExitCode 2 }
                $action = ([string]$parsed.Positionals[0]).ToLowerInvariant()
                $state = switch ($action) {
                    "start" { Set-AgentLocalCiServiceState $home $repository $policy $true }
                    "stop" { Set-AgentLocalCiServiceState $home $repository $policy $false }
                    "restart" { Set-AgentLocalCiServiceState $home $repository $policy $true }
                    "status" { Get-AgentLocalCiServiceState $home $repository $policy }
                    default { Throw-AgentLocalCi -Message "Unknown service action '$action'" -ExitCode 2 }
                }
                $state | ConvertTo-Json -Depth 10
                return 0
            }
            "uninstall" {
                Assert-AgentLocalCiCliOptions $parsed @("home") 0
                $result = Invoke-AgentLocalCiUninstall $home
                $result | ConvertTo-Json -Depth 10
                return 0
            }
            default {
                Throw-AgentLocalCi -Message "Unknown command '$($parsed.Command)'. Run 'agentlocalci help'." -ExitCode 2
            }
        }
    }
    catch [Management.Automation.PipelineStoppedException] {
        [Console]::Error.WriteLine("AgentLocalCI interrupted")
        return 130
    }
    catch {
        $code = Get-AgentLocalCiExceptionExitCode $_.Exception
        [Console]::Error.WriteLine((ConvertTo-AgentLocalCiRedactedText $_.Exception.Message))
        return $code
    }
}

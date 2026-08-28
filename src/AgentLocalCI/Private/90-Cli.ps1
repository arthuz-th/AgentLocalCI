function ConvertFrom-AgentLocalCiCliArguments {
    param([AllowEmptyCollection()][string[]]$Arguments)
    if ($Arguments.Count -eq 0) { return [pscustomobject]@{ Command = "help"; Options = @{}; Positionals = @() } }
    $command = $Arguments[0].ToLowerInvariant()
    $options = [ordered]@{}
    $positionals = [Collections.Generic.List[string]]::new()
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

function Assert-AgentLocalCiCliExclusiveFlags {
    param(
        [Parameter(Mandatory = $true)][object]$Parsed,
        [Parameter(Mandatory = $true)][string[]]$Names
    )
    $present = @($Names | Where-Object { $Parsed.Options.Contains($_) })
    if ($present.Count -gt 1) { Throw-AgentLocalCi -Message ("Options " + (($present | ForEach-Object { "--$_" }) -join ", ") + " cannot be combined") -ExitCode 2 }
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

function Write-AgentLocalCiRunCliResult {
    param([Parameter(Mandatory = $true)][object]$Run)
    ""
    "AgentLocalCI result: $($Run.Result)"
    "Exact commit: $($Run.Report.target_sha)"
    "Profile: $($Run.Report.profile.name)"
    "Cleanup: $($Run.Report.cleanup.status)"
    "HTML report: $($Run.HtmlPath)"
    "JSON report: $($Run.ReportPath)"
}

function Get-AgentLocalCiHelpText {
    return @"
AgentLocalCI $script:AgentLocalCiVersion
Exact-commit local CI for Windows, macOS, and Linux.

Start here (no SHA knowledge required):
  agentlocalci quickstart [--commit] [--open]
      Check the machine, detect npm or Gradle, create a safe config, and run it.
      --commit creates one narrow commit containing only .agentlocalci/pipeline.yml.

  agentlocalci check [--profile NAME] [--open]
      Validate the current exact HEAD. Dirty working trees are refused.

  agentlocalci why [--json]
      Show when AgentLocalCI is useful and when hosted CI is still the better tool.

Helpful commands:
  agentlocalci doctor [--build-image] [--json]
  agentlocalci init [--json]
  agentlocalci report [RUN_ID] [--open | --html | --json]
  agentlocalci status [--json]
  agentlocalci hook <install|remove|status> [--profile NAME]
  agentlocalci clean [--images]

Advanced exact-target commands:
  agentlocalci validate-config --sha COMMIT
  agentlocalci profiles [--sha COMMIT]
  agentlocalci run --sha COMMIT [--profile NAME] [--open]
  agentlocalci service <start|stop|restart|status>
  agentlocalci uninstall
  agentlocalci version

Common options:
  --repository PATH   Target Git worktree root. The current directory is the default.
  --home PATH         AgentLocalCI state directory.
  --policy PATH       Machine policy inside the AgentLocalCI home.
  --wait-seconds N    Wait for another local run to finish.

Safety model: project code runs from one exact committed tree in a fresh non-root Linux
container with no host repository mount, no Docker socket, no forwarded credentials, and
network=none during validation. Dependency downloads are prepared separately through an
exact-host allowlist. AgentLocalCI is not a remote runner or a deployment system.
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
                "AgentLocalCI $script:AgentLocalCiVersion (schema $script:AgentLocalCiSchemaVersion; host $(Get-AgentLocalCiHostPlatform)/$(Get-AgentLocalCiHostArchitecture))"
                return 0
            }
            "why" {
                Assert-AgentLocalCiCliOptions $parsed @("json") 0
                if (Test-AgentLocalCiCliFlag $parsed "json") { Get-AgentLocalCiWhyInformation | ConvertTo-Json -Depth 20 }
                else { Get-AgentLocalCiWhyText }
                return 0
            }
            "doctor" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("build-image", "json")) 0
                $doctor = Invoke-AgentLocalCiDoctor $home $repository $policy -BuildImage:(Test-AgentLocalCiCliFlag $parsed "build-image")
                if (Test-AgentLocalCiCliFlag $parsed "json") { $doctor | ConvertTo-Json -Depth 20 }
                else {
                    foreach ($check in @($doctor.Checks)) {
                        "[{0}] {1}: {2}" -f $(if ($check.passed) { "PASS" } else { "FAIL" }), $check.name, $check.detail
                        if (-not $check.passed -and -not [string]::IsNullOrWhiteSpace([string]$check.fix)) { "       Fix: $($check.fix)" }
                    }
                }
                return $(if ($doctor.Passed) { 0 } else { 3 })
            }
            "init" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("json")) 0
                $result = Initialize-AgentLocalCiRepository $home $repository $policy
                if (Test-AgentLocalCiCliFlag $parsed "json") { $result | ConvertTo-Json -Depth 20 }
                else {
                    "Created $($result.Created)"
                    "Detected: $($result.Detected)"
                    "Default profile: $($result.DefaultProfile); acceptance=$($result.Acceptance)"
                    "Stages: $(@($result.Stages) -join ', ')"
                    foreach ($next in @($result.Next)) { "Next: $next" }
                }
                return 0
            }
            "quickstart" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("profile", "wait-seconds", "commit", "open", "json")) 0
                $profileName = if ($parsed.Options.Contains("profile")) { Get-AgentLocalCiCliStringOption $parsed "profile" -Required } else { $null }
                $wait = Get-AgentLocalCiCliIntOption $parsed "wait-seconds" 0 0 86400
                $result = Invoke-AgentLocalCiQuickstart $home $repository $policy $profileName $wait -CommitConfiguration:(Test-AgentLocalCiCliFlag $parsed "commit") -OpenReport:(Test-AgentLocalCiCliFlag $parsed "open")
                if (Test-AgentLocalCiCliFlag $parsed "json") { $result | ConvertTo-Json -Depth 100 }
                elseif (-not $result.Ran) {
                    "AgentLocalCI created a safe starter configuration."
                    "Detected: $($result.Setup.Detected)"
                    "Stages: $(@($result.Setup.Stages) -join ', ')"
                    "Next: $($result.Next)"
                }
                else { Write-AgentLocalCiRunCliResult $result.Run }
                return [int]$result.ExitCode
            }
            "check" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("profile", "wait-seconds", "open", "json")) 0
                $profileName = if ($parsed.Options.Contains("profile")) { Get-AgentLocalCiCliStringOption $parsed "profile" -Required } else { $null }
                $wait = Get-AgentLocalCiCliIntOption $parsed "wait-seconds" 0 0 86400
                $run = Invoke-AgentLocalCiCheck $home $repository $policy $profileName $wait -OpenReport:(Test-AgentLocalCiCliFlag $parsed "open")
                if (Test-AgentLocalCiCliFlag $parsed "json") { $run.Report | ConvertTo-Json -Depth 100 }
                else { Write-AgentLocalCiRunCliResult $run }
                return [int]$run.ExitCode
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
                $context = Get-AgentLocalCiContext $home $repository $policy
                $sha = if ($parsed.Options.Contains("sha")) { Get-AgentLocalCiCliStringOption $parsed "sha" -Required } else { Get-AgentLocalCiExactHead $context.RepositoryRoot }
                $pipeline = Read-AgentLocalCiPipelineFromCommit $context (Resolve-AgentLocalCiCommit $context.RepositoryRoot $sha)
                foreach ($property in $pipeline.profiles.PSObject.Properties) {
                    $profile = $property.Value
                    "{0}: acceptance={1}; stages={2}; gaps={3}; {4}" -f $property.Name, $profile.acceptance, @($profile.stages).Count, @($profile.gaps).Count, $profile.description
                }
                return 0
            }
            "run" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("sha", "profile", "wait-seconds", "open", "json")) 0
                $sha = Get-AgentLocalCiCliStringOption $parsed "sha" -Required
                $profileName = if ($parsed.Options.Contains("profile")) { Get-AgentLocalCiCliStringOption $parsed "profile" -Required } else { $null }
                $wait = Get-AgentLocalCiCliIntOption $parsed "wait-seconds" 0 0 86400
                $run = Invoke-AgentLocalCiRun $home $repository $policy $sha $profileName $wait
                if (Test-AgentLocalCiCliFlag $parsed "open") { [void](Open-AgentLocalCiPath $run.HtmlPath) }
                if (Test-AgentLocalCiCliFlag $parsed "json") { $run.Report | ConvertTo-Json -Depth 100 }
                else { Write-AgentLocalCiRunCliResult $run }
                return [int]$run.ExitCode
            }
            "status" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("json")) 0
                $context = Get-AgentLocalCiContext $home $repository $policy -RepositoryOptional
                $records = Get-AgentLocalCiStatusRecords $context
                if (Test-AgentLocalCiCliFlag $parsed "json") { $records | ConvertTo-Json -Depth 20 }
                elseif ($records.Count -eq 0) { "No AgentLocalCI runs found." }
                else { foreach ($record in $records) { "{0}  {1,-20} {2}  {3}" -f $record.run_id, $record.status, $record.target_sha, $record.profile } }
                return 0
            }
            "report" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("json", "html", "open")) 1
                Assert-AgentLocalCiCliExclusiveFlags $parsed @("json", "html", "open")
                $context = Get-AgentLocalCiContext $home $repository $policy -RepositoryOptional
                $runId = if ($parsed.Positionals.Count -eq 1) { [string]$parsed.Positionals[0] } else { $null }
                $report = Get-AgentLocalCiRunReport $context $runId
                if (Test-AgentLocalCiCliFlag $parsed "json") { Get-Content -LiteralPath $report.Path -Raw -Encoding UTF8 }
                elseif (Test-AgentLocalCiCliFlag $parsed "html") { $report.Html }
                elseif (Test-AgentLocalCiCliFlag $parsed "open") { "Opened: $(Open-AgentLocalCiPath $report.Html)" }
                else { Get-Content -LiteralPath $report.Summary -Raw -Encoding UTF8 }
                return 0
            }
            "hook" {
                Assert-AgentLocalCiCliOptions $parsed @("repository", "profile", "json") 1
                if ($parsed.Positionals.Count -ne 1) { Throw-AgentLocalCi -Message "hook requires install, remove, or status" -ExitCode 2 }
                $root = Get-AgentLocalCiRepositoryRoot $repository
                $action = ([string]$parsed.Positionals[0]).ToLowerInvariant()
                $hookResult = switch ($action) {
                    "install" {
                        $hookProfile = if ($parsed.Options.Contains("profile")) { Get-AgentLocalCiCliStringOption $parsed "profile" -Required } else { $null }
                        Install-AgentLocalCiPrePushHook $root $hookProfile
                    }
                    "remove" { Remove-AgentLocalCiPrePushHook $root }
                    "status" { Get-AgentLocalCiHookState $root }
                    default { Throw-AgentLocalCi -Message "Unknown hook action '$action'" -ExitCode 2 }
                }
                if (Test-AgentLocalCiCliFlag $parsed "json") { $hookResult | ConvertTo-Json -Depth 20 }
                else { $hookResult | Format-List | Out-String }
                return 0
            }
            "clean" {
                Assert-AgentLocalCiCliOptions $parsed ($global + @("images", "wait-seconds", "json")) 0
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
            default { Throw-AgentLocalCi -Message "Unknown command '$($parsed.Command)'. Run 'agentlocalci help'." -ExitCode 2 }
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

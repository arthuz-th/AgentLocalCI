function Assert-AgentLocalCiDependencyDefinition {
    param(
        [AllowNull()][object]$Dependencies,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )
    $normalized = [ordered]@{ npm = $null; gradle = $null }
    if ($null -eq $Dependencies) { return [pscustomobject]$normalized }
    Assert-AgentLocalCiKnownProperties $Dependencies @("npm", "gradle") "pipeline dependencies"
    if ($Dependencies.PSObject.Properties["npm"] -and $null -ne $Dependencies.npm) {
        Assert-AgentLocalCiKnownProperties $Dependencies.npm @("working_directory", "lockfile") "pipeline dependencies.npm"
        $workdir = [string](Get-AgentLocalCiRequiredProperty $Dependencies.npm "working_directory" "pipeline dependencies.npm")
        $lockfile = [string](Get-AgentLocalCiRequiredProperty $Dependencies.npm "lockfile" "pipeline dependencies.npm")
        [void](Resolve-AgentLocalCiRelativePath $RepositoryRoot $workdir)
        if (-not (Test-AgentLocalCiSafeRelativePath $lockfile)) { Throw-AgentLocalCi -Message "Unsafe npm lockfile path" -ExitCode 2 }
        $normalized.npm = [pscustomobject]@{ working_directory = $workdir.Replace('\', '/'); lockfile = $lockfile.Replace('\', '/') }
    }
    if ($Dependencies.PSObject.Properties["gradle"] -and $null -ne $Dependencies.gradle) {
        Assert-AgentLocalCiKnownProperties $Dependencies.gradle @("working_directory", "wrapper") "pipeline dependencies.gradle"
        $workdir = [string](Get-AgentLocalCiRequiredProperty $Dependencies.gradle "working_directory" "pipeline dependencies.gradle")
        $wrapper = [string](Get-AgentLocalCiRequiredProperty $Dependencies.gradle "wrapper" "pipeline dependencies.gradle")
        [void](Resolve-AgentLocalCiRelativePath $RepositoryRoot $workdir)
        if (-not (Test-AgentLocalCiSafeRelativePath $wrapper)) { Throw-AgentLocalCi -Message "Unsafe Gradle wrapper path" -ExitCode 2 }
        $normalized.gradle = [pscustomobject]@{ working_directory = $workdir.Replace('\', '/'); wrapper = $wrapper.Replace('\', '/') }
    }
    return [pscustomobject]$normalized
}

function Assert-AgentLocalCiCommandVector {
    param(
        [Parameter(Mandatory = $true)][string[]]$Command,
        [Parameter(Mandatory = $true)][string]$StageId
    )
    if ($Command.Count -lt 1) { Throw-AgentLocalCi -Message "stage '$StageId' command is empty" -ExitCode 2 }
    foreach ($argument in $Command) {
        if ($argument.Length -gt 32768 -or $argument.IndexOf([char]0) -ge 0 -or $argument -match '[\x00-\x1F\x7F]') {
            Throw-AgentLocalCi -Message "stage '$StageId' contains an unsafe argv entry" -ExitCode 2
        }
        if (Test-AgentLocalCiSecretLikeText $argument) { Throw-AgentLocalCi -Message "stage '$StageId' contains secret-like command text" -ExitCode 4 }
    }
    $executableName = (($Command[0].Replace([char]92, '/') -split '/')[-1]).ToLowerInvariant()
    $arguments = @($Command | Select-Object -Skip 1)
    $forbidden = switch ($executableName) {
        { $_ -in @('sh', 'bash', 'dash', 'zsh', 'ksh') } { @('-c', '-lc') }
        { $_ -in @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe') } { @('-c', '-command', '-encodedcommand', '-ec', '-commandwithargs') }
        { $_ -in @('cmd', 'cmd.exe') } { @('/c', '/k') }
        { $_ -in @('node', 'node.exe') } { @('-e', '--eval', '-p', '--print') }
        { $_ -in @('python', 'python.exe', 'python3', 'python3.exe', 'perl', 'perl.exe', 'ruby', 'ruby.exe') } { @('-c', '-e') }
        default { @() }
    }
    foreach ($argument in $arguments) {
        if ($forbidden -ccontains $argument.ToLowerInvariant()) {
            Throw-AgentLocalCi -Message "stage '$StageId' uses a command-string interpreter flag; commit a script file and invoke that file instead" -ExitCode 2
        }
    }
}

function Assert-AgentLocalCiPipeline {
    param(
        [Parameter(Mandatory = $true)][object]$Pipeline,
        [Parameter(Mandatory = $true)][object]$Policy,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )
    Assert-AgentLocalCiKnownProperties $Pipeline @("schema_version", "project", "default_profile", "dependency_hosts", "environment", "dependencies", "profiles") "pipeline"
    if ([int](Get-AgentLocalCiRequiredProperty $Pipeline "schema_version" "pipeline") -ne 1) { Throw-AgentLocalCi -Message "Unsupported pipeline schema" -ExitCode 2 }
    $project = Get-AgentLocalCiRequiredProperty $Pipeline "project" "pipeline"
    Assert-AgentLocalCiKnownProperties $project @("name") "pipeline project"
    $projectName = [string](Get-AgentLocalCiRequiredProperty $project "name" "pipeline project")
    if ($projectName.Length -lt 1 -or $projectName.Length -gt 80 -or $projectName -match '[\x00-\x1F\x7F]') { Throw-AgentLocalCi -Message "project.name must contain 1..80 safe display characters" -ExitCode 2 }
    $defaultProfile = [string](Get-AgentLocalCiRequiredProperty $Pipeline "default_profile" "pipeline")
    if ($defaultProfile -cnotmatch '^[a-z][a-z0-9-]{0,63}$') { Throw-AgentLocalCi -Message "Invalid default_profile" -ExitCode 2 }

    $policyHosts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hostName in @($Policy.allowed_dependency_hosts)) { [void]$policyHosts.Add([string]$hostName) }
    $requestedHostsValue = @(Get-AgentLocalCiArrayProperty -Value $Pipeline -Name "dependency_hosts" -Context "pipeline" -AllowEmpty)
    $requestedHosts = @(ConvertTo-AgentLocalCiStringArray -Value $requestedHostsValue -Context "pipeline dependency_hosts" -AllowEmpty)
    $hostSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hostName in $requestedHosts) {
        if (-not (Test-AgentLocalCiDependencyHost $hostName)) { Throw-AgentLocalCi -Message "Unsafe dependency host: $hostName" -ExitCode 2 }
        if (-not $policyHosts.Contains($hostName)) { Throw-AgentLocalCi -Message "Dependency host denied by machine policy: $hostName" -ExitCode 4 }
        if (-not $hostSet.Add($hostName)) { Throw-AgentLocalCi -Message "Duplicate dependency host: $hostName" -ExitCode 2 }
    }
    $globalEnvironment = ConvertTo-AgentLocalCiEnvironmentMap $(if ($Pipeline.PSObject.Properties["environment"]) { $Pipeline.environment } else { $null }) $Policy "pipeline"
    $dependencies = Assert-AgentLocalCiDependencyDefinition $(if ($Pipeline.PSObject.Properties["dependencies"]) { $Pipeline.dependencies } else { $null }) $RepositoryRoot
    $profiles = Get-AgentLocalCiRequiredProperty $Pipeline "profiles" "pipeline"
    if (@($profiles.PSObject.Properties).Count -eq 0) { Throw-AgentLocalCi -Message "profiles must not be empty" -ExitCode 2 }

    $normalizedProfiles = [ordered]@{}
    foreach ($profileProperty in $profiles.PSObject.Properties) {
        $profileName = [string]$profileProperty.Name
        if ($profileName -cnotmatch '^[a-z][a-z0-9-]{0,63}$') { Throw-AgentLocalCi -Message "Invalid profile '$profileName'" -ExitCode 2 }
        $profile = $profileProperty.Value
        Assert-AgentLocalCiKnownProperties $profile @("description", "acceptance", "gaps", "stages") "profile '$profileName'"
        $description = [string](Get-AgentLocalCiRequiredProperty $profile "description" "profile '$profileName'")
        if ($description.Length -lt 1 -or $description.Length -gt 500 -or $description -match '[\x00-\x1F\x7F]') { Throw-AgentLocalCi -Message "profile '$profileName' description must contain 1..500 safe display characters" -ExitCode 2 }
        $acceptance = Get-AgentLocalCiRequiredProperty $profile "acceptance" "profile '$profileName'"
        if ($acceptance -isnot [bool]) { Throw-AgentLocalCi -Message "profile '$profileName' acceptance must be boolean" -ExitCode 2 }
        $gapsValue = @(Get-AgentLocalCiArrayProperty -Value $profile -Name "gaps" -Context "profile '$profileName'" -AllowMissing -AllowEmpty)
        $gaps = @(ConvertTo-AgentLocalCiStringArray -Value $gapsValue -Context "profile '$profileName' gaps" -AllowEmpty)
        foreach ($gap in $gaps) { if ($gap.Length -gt 1000 -or $gap -match '[\x00-\x1F\x7F]') { Throw-AgentLocalCi -Message "profile '$profileName' gap text is unsafe or too long" -ExitCode 2 } }
        $stages = @(Get-AgentLocalCiArrayProperty -Value $profile -Name "stages" -Context "profile '$profileName'")
        if ($stages.Count -lt 1 -or $stages.Count -gt 100) { Throw-AgentLocalCi -Message "profile '$profileName' must contain 1..100 stages" -ExitCode 2 }
        $stageIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $normalizedStages = New-Object System.Collections.Generic.List[object]
        foreach ($stage in $stages) {
            Assert-AgentLocalCiKnownProperties $stage @("id", "command", "working_directory", "needs", "environment", "timeout_seconds") "profile '$profileName' stage"
            $stageId = [string](Get-AgentLocalCiRequiredProperty $stage "id" "profile '$profileName' stage")
            if ($stageId -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or -not $stageIds.Add($stageId)) { Throw-AgentLocalCi -Message "Invalid or duplicate stage '$stageId' in '$profileName'" -ExitCode 2 }
            $commandValue = @(Get-AgentLocalCiArrayProperty -Value $stage -Name "command" -Context "stage '$stageId'")
            $command = @(ConvertTo-AgentLocalCiStringArray -Value $commandValue -Context "stage '$stageId' command")
            if ($command.Count -gt 128) { Throw-AgentLocalCi -Message "stage '$stageId' has too many argv entries" -ExitCode 2 }
            Assert-AgentLocalCiCommandVector $command $stageId
            $workdir = [string](Get-AgentLocalCiRequiredProperty $stage "working_directory" "stage '$stageId'")
            [void](Resolve-AgentLocalCiRelativePath $RepositoryRoot $workdir)
            $needsValue = @(Get-AgentLocalCiArrayProperty -Value $stage -Name "needs" -Context "stage '$stageId'" -AllowMissing -AllowEmpty)
            $needs = @(ConvertTo-AgentLocalCiStringArray -Value $needsValue -Context "stage '$stageId' needs" -AllowEmpty)
            $needsSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($need in $needs) {
                if ($need -notin @("npm", "gradle") -or -not $needsSet.Add($need)) { Throw-AgentLocalCi -Message "stage '$stageId' has unsupported or duplicate need '$need'" -ExitCode 2 }
                if ($need -eq "npm" -and $null -eq $dependencies.npm) { Throw-AgentLocalCi -Message "stage '$stageId' needs npm but dependencies.npm is absent" -ExitCode 2 }
                if ($need -eq "gradle" -and $null -eq $dependencies.gradle) { Throw-AgentLocalCi -Message "stage '$stageId' needs gradle but dependencies.gradle is absent" -ExitCode 2 }
            }
            $environment = ConvertTo-AgentLocalCiEnvironmentMap $(if ($stage.PSObject.Properties["environment"]) { $stage.environment } else { $null }) $Policy "stage '$stageId'"
            $timeout = if ($stage.PSObject.Properties["timeout_seconds"]) { [int]$stage.timeout_seconds } else { [int]$Policy.resources.stage_timeout_seconds }
            if ($timeout -lt 1 -or $timeout -gt [int]$Policy.resources.stage_timeout_seconds) { Throw-AgentLocalCi -Message "stage '$stageId' timeout exceeds machine policy" -ExitCode 4 }
            $normalizedStages.Add([pscustomobject]@{ id = $stageId; command = $command; working_directory = $workdir.Replace('\', '/'); needs = @($needsSet | Sort-Object); environment = $environment; timeout_seconds = $timeout })
        }
        $normalizedProfiles[$profileName] = [pscustomobject]@{ name = $profileName; description = $description; acceptance = [bool]$acceptance; gaps = $gaps; stages = $normalizedStages.ToArray() }
    }
    if (-not $normalizedProfiles.Contains($defaultProfile)) { Throw-AgentLocalCi -Message "default_profile '$defaultProfile' is not defined" -ExitCode 2 }
    foreach ($requiredProfile in @($Policy.required_profiles)) {
        if (-not $normalizedProfiles.Contains([string]$requiredProfile)) { Throw-AgentLocalCi -Message "Machine policy requires missing profile '$requiredProfile'" -ExitCode 4 }
    }
    foreach ($requirement in $Policy.required_stage_ids.PSObject.Properties) {
        if (-not $normalizedProfiles.Contains($requirement.Name)) { Throw-AgentLocalCi -Message "Machine policy requires missing profile '$($requirement.Name)'" -ExitCode 4 }
        $present = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($stage in @($normalizedProfiles[$requirement.Name].stages)) { [void]$present.Add([string]$stage.id) }
        foreach ($requiredStage in @($requirement.Value)) { if (-not $present.Contains([string]$requiredStage)) { Throw-AgentLocalCi -Message "Machine policy requires missing stage '$requiredStage' in '$($requirement.Name)'" -ExitCode 4 } }
    }
    return [pscustomobject]@{
        schema_version = 1
        project = [pscustomobject]@{ name = $projectName }
        default_profile = $defaultProfile
        dependency_hosts = @($hostSet | Sort-Object)
        environment = $globalEnvironment
        dependencies = $dependencies
        profiles = [pscustomobject]$normalizedProfiles
    }
}

function Get-AgentLocalCiProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Pipeline,
        [AllowNull()][string]$ProfileName
    )
    $name = if ([string]::IsNullOrWhiteSpace($ProfileName)) { [string]$Pipeline.default_profile } else { $ProfileName.ToLowerInvariant() }
    $property = $Pipeline.profiles.PSObject.Properties[$name]
    if ($null -eq $property) { Throw-AgentLocalCi -Message "Unknown profile '$name'" -ExitCode 2 }
    return $property.Value
}

function Get-AgentLocalCiDefaultPipelineObject {
    $pipeline = [ordered]@{
        schema_version = 1
        project = [ordered]@{ name = "example-project" }
        default_profile = "standard"
        dependency_hosts = @("registry.npmjs.org")
        environment = [ordered]@{ NODE_ENV = "test" }
        dependencies = [ordered]@{ npm = [ordered]@{ working_directory = "."; lockfile = "package-lock.json" } }
        profiles = [ordered]@{
            fast = [ordered]@{
                description = "Fast local feedback; not completion evidence"
                acceptance = $false
                gaps = @("Tests and production build are omitted.")
                stages = @(
                    [ordered]@{ id = "lint"; command = @("npm", "run", "lint"); working_directory = "."; needs = @("npm"); timeout_seconds = 900 }
                )
            }
            standard = [ordered]@{
                description = "Repository-defined local acceptance profile"
                acceptance = $true
                gaps = @("Hosted services and deployment are outside this offline profile.")
                stages = @(
                    [ordered]@{ id = "lint"; command = @("npm", "run", "lint"); working_directory = "."; needs = @("npm"); timeout_seconds = 900 },
                    [ordered]@{ id = "test"; command = @("npm", "test"); working_directory = "."; needs = @("npm"); timeout_seconds = 1800 },
                    [ordered]@{ id = "build"; command = @("npm", "run", "build"); working_directory = "."; needs = @("npm"); timeout_seconds = 1800 }
                )
            }
        }
    }
    return ($pipeline | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50)
}

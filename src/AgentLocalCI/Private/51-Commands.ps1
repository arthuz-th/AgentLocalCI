function Get-AgentLocalCiPackageScripts {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $packagePath = Join-Path $RepositoryRoot "package.json"
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { return [pscustomobject]@{} }
    Assert-AgentLocalCiNoReparseAncestor $packagePath
    $item = Get-Item -LiteralPath $packagePath -Force
    if ($item.Length -gt 1MB) { Throw-AgentLocalCi -Message "package.json exceeds the 1 MiB beginner-detection bound" -ExitCode 2 }
    try { $package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50 }
    catch { Throw-AgentLocalCi -Message "package.json is invalid JSON; automatic setup cannot continue" -ExitCode 2 }
    $result = [ordered]@{}
    if ($null -eq $package.PSObject.Properties["scripts"] -or $null -eq $package.scripts) { return [pscustomobject]$result }
    foreach ($property in $package.scripts.PSObject.Properties) {
        if ($property.Name -cnotmatch '^[A-Za-z0-9:_-]{1,80}$' -or $property.Value -isnot [string]) { continue }
        $result[$property.Name] = [string]$property.Value
    }
    return [pscustomobject]$result
}

function Test-AgentLocalCiUsefulNpmScript {
    param(
        [Parameter(Mandatory = $true)][object]$Scripts,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $property = $Scripts.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $false }
    $value = [string]$property.Value
    if ($Name -ceq "test" -and $value -match '(?i)no test specified|exit\s+1') { return $false }
    return $true
}

function New-AgentLocalCiNpmStarterPipeline {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)][object]$Scripts
    )
    $stages = [Collections.Generic.List[object]]::new()
    $candidates = @(
        [pscustomobject]@{ Script = "lint"; Id = "lint"; Command = @("npm", "run", "lint"); Timeout = 900 },
        [pscustomobject]@{ Script = "typecheck"; Id = "typecheck"; Command = @("npm", "run", "typecheck"); Timeout = 900 },
        [pscustomobject]@{ Script = "type-check"; Id = "typecheck"; Command = @("npm", "run", "type-check"); Timeout = 900 },
        [pscustomobject]@{ Script = "check-types"; Id = "typecheck"; Command = @("npm", "run", "check-types"); Timeout = 900 },
        [pscustomobject]@{ Script = "test"; Id = "test"; Command = @("npm", "test"); Timeout = 1800 },
        [pscustomobject]@{ Script = "build"; Id = "build"; Command = @("npm", "run", "build"); Timeout = 1800 }
    )
    $stageIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in $candidates) {
        if (-not (Test-AgentLocalCiUsefulNpmScript $Scripts $candidate.Script) -or -not $stageIds.Add($candidate.Id)) { continue }
        $stages.Add([ordered]@{
            id = $candidate.Id
            command = $candidate.Command
            working_directory = "."
            needs = @("npm")
            timeout_seconds = $candidate.Timeout
        })
    }
    if ($stages.Count -eq 0) { return $null }
    $fastStages = @($stages.ToArray() | Where-Object { $_.id -in @("lint", "typecheck") })
    if ($fastStages.Count -eq 0) { $fastStages = @($stages[0]) }
    return [ordered]@{
        schema_version = 1
        project = [ordered]@{ name = $ProjectName }
        default_profile = "standard"
        dependency_hosts = @("registry.npmjs.org")
        environment = [ordered]@{ NODE_ENV = "test" }
        dependencies = [ordered]@{ npm = [ordered]@{ working_directory = "."; lockfile = "package-lock.json" } }
        profiles = [ordered]@{
            fast = [ordered]@{
                description = "Fast checks detected from package.json; useful before every push"
                acceptance = $false
                gaps = @("The full detected test and build set is not included in this fast profile.")
                stages = $fastStages
            }
            standard = [ordered]@{
                description = "Detected npm lint, typecheck, test, and build scripts that exist in package.json"
                acceptance = $true
                gaps = @("Hosted services, browser/device matrices, deployment, and production authorization remain outside local CI.")
                stages = $stages.ToArray()
            }
        }
    }
}

function Get-AgentLocalCiGradleStarterDefinition {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    foreach ($relativeWrapper in @("gradlew", "android/gradlew", "apps/android/gradlew")) {
        $candidate = Join-Path $RepositoryRoot $relativeWrapper
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        Assert-AgentLocalCiNoReparseAncestor $candidate
        $workdir = Split-Path -Parent ($relativeWrapper.Replace([char]92, '/'))
        if ([string]::IsNullOrWhiteSpace($workdir)) { $workdir = "." }
        return [pscustomobject]@{ WorkingDirectory = $workdir; Wrapper = "gradlew"; RelativeWrapper = $relativeWrapper.Replace([char]92, '/') }
    }
    return $null
}

function New-AgentLocalCiGradleStarterPipeline {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)][object]$Gradle
    )
    return [ordered]@{
        schema_version = 1
        project = [ordered]@{ name = $ProjectName }
        default_profile = "standard"
        dependency_hosts = @(
            "dl.google.com", "downloads.gradle.org", "github.com",
            "github-releases.githubusercontent.com", "maven.google.com",
            "objects.githubusercontent.com", "plugins.gradle.org",
            "plugins-artifacts.gradle.org", "release-assets.githubusercontent.com",
            "repo.maven.apache.org", "services.gradle.org"
        )
        environment = [ordered]@{}
        dependencies = [ordered]@{ gradle = [ordered]@{ working_directory = $Gradle.WorkingDirectory; wrapper = $Gradle.Wrapper } }
        profiles = [ordered]@{
            fast = [ordered]@{
                description = "Fast Gradle compile and verification entry point"
                acceptance = $false
                gaps = @("The full Gradle check task is omitted from this fast profile.")
                stages = @([ordered]@{ id = "gradle-classes"; command = @("./gradlew", "classes"); working_directory = $Gradle.WorkingDirectory; needs = @("gradle"); timeout_seconds = 1800 })
            }
            standard = [ordered]@{
                description = "Repository-defined Gradle check task using the committed wrapper"
                acceptance = $true
                gaps = @("Emulators, hardware devices, hosted services, signing, deployment, and production authorization are outside this offline profile.")
                stages = @([ordered]@{ id = "gradle-check"; command = @("./gradlew", "check"); working_directory = $Gradle.WorkingDirectory; needs = @("gradle"); timeout_seconds = 1800 })
            }
        }
    }
}

function New-AgentLocalCiDiagnosticStarterPipeline {
    param([Parameter(Mandatory = $true)][string]$ProjectName)
    return [ordered]@{
        schema_version = 1
        project = [ordered]@{ name = $ProjectName }
        default_profile = "diagnostic"
        dependency_hosts = @()
        environment = [ordered]@{}
        dependencies = [ordered]@{}
        profiles = [ordered]@{
            diagnostic = [ordered]@{
                description = "Safe starter only; add repository-specific test commands before treating it as acceptance evidence"
                acceptance = $false
                gaps = @("No supported package-lock or Gradle wrapper with known checks was detected.")
                stages = @([ordered]@{ id = "source-present"; command = @("/usr/bin/test", "-f", ".agentlocalci/pipeline.yml"); working_directory = "."; needs = @(); timeout_seconds = 300 })
            }
        }
    }
}

function Initialize-AgentLocalCiRepository {
    param(
        [AllowNull()][string]$Home,
        [AllowNull()][string]$RepositoryRoot,
        [AllowNull()][string]$PolicyPath
    )
    $context = Get-AgentLocalCiContext $Home $RepositoryRoot $PolicyPath
    $path = Resolve-AgentLocalCiRelativePath $context.RepositoryRoot $script:AgentLocalCiPipelinePath
    if (Test-Path -LiteralPath $path) { Throw-AgentLocalCi -Message "$script:AgentLocalCiPipelinePath already exists" -ExitCode 4 }
    $projectName = Split-Path -Leaf $context.RepositoryRoot
    $pipeline = $null
    $detected = "generic-diagnostic"
    if (
        (Test-Path -LiteralPath (Join-Path $context.RepositoryRoot "package-lock.json") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $context.RepositoryRoot "package.json") -PathType Leaf)
    ) {
        $scripts = Get-AgentLocalCiPackageScripts $context.RepositoryRoot
        $pipeline = New-AgentLocalCiNpmStarterPipeline $projectName $scripts
        if ($null -ne $pipeline) { $detected = "npm" }
    }
    if ($null -eq $pipeline) {
        $gradle = Get-AgentLocalCiGradleStarterDefinition $context.RepositoryRoot
        if ($null -ne $gradle) {
            $pipeline = New-AgentLocalCiGradleStarterPipeline $projectName $gradle
            $detected = "gradle:$($gradle.RelativeWrapper)"
        }
    }
    if ($null -eq $pipeline) { $pipeline = New-AgentLocalCiDiagnosticStarterPipeline $projectName }
    $pipelineObject = $pipeline | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
    [void](Assert-AgentLocalCiPipeline $pipelineObject $context.Policy $context.RepositoryRoot)
    $directory = Split-Path -Parent $path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    Assert-AgentLocalCiNoReparseAncestor $directory
    [IO.File]::WriteAllText($path, ($pipelineObject | ConvertTo-Json -Depth 50), [Text.UTF8Encoding]::new($false))
    $defaultProfile = $pipelineObject.profiles.PSObject.Properties[[string]$pipelineObject.default_profile].Value
    return [pscustomobject]@{
        Created = $script:AgentLocalCiPipelinePath
        Project = $projectName
        Detected = $detected
        DefaultProfile = [string]$pipelineObject.default_profile
        Acceptance = [bool]$defaultProfile.acceptance
        Stages = @($defaultProfile.stages | ForEach-Object { [string]$_.id })
        Next = @(
            "Review .agentlocalci/pipeline.yml.",
            "Commit it so AgentLocalCI can validate an exact immutable tree.",
            "Run 'agentlocalci check' or use 'agentlocalci quickstart --commit' for the guided one-command path."
        )
    }
}

function Remove-AgentLocalCiManagedShellPath {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) { return $false }
    $text = [IO.File]::ReadAllText($ProfilePath, [Text.Encoding]::UTF8)
    $pattern = '(?ms)^# >>> AgentLocalCI PATH >>>\r?\n.*?^# <<< AgentLocalCI PATH <<<\r?\n?'
    $updated = [Regex]::Replace($text, $pattern, "")
    if ($updated -ceq $text) { return $false }
    [IO.File]::WriteAllText($ProfilePath, $updated, [Text.UTF8Encoding]::new($false))
    return $true
}

function Remove-AgentLocalCiBinFromUserPath {
    param(
        [Parameter(Mandatory = $true)][string]$BinPath,
        [AllowNull()][string]$ProfilePath
    )
    if ((Get-AgentLocalCiHostPlatform) -ceq "windows") {
        $current = [Environment]::GetEnvironmentVariable("Path", "User")
        $normalized = [IO.Path]::GetFullPath($BinPath).TrimEnd([char[]]@('\', '/'))
        $kept = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Where-Object {
            try { -not (Test-AgentLocalCiPathEquals ([IO.Path]::GetFullPath($_).TrimEnd([char[]]@('\', '/'))) $normalized) }
            catch { $true }
        })
        [Environment]::SetEnvironmentVariable("Path", ($kept -join ';'), "User")
        return
    }
    $resolvedProfile = if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
        if ((Get-AgentLocalCiHostPlatform) -ceq "macos") { Join-Path (Get-AgentLocalCiUserHome) ".zprofile" } else { Join-Path (Get-AgentLocalCiUserHome) ".profile" }
    }
    else { $ProfilePath }
    [void](Remove-AgentLocalCiManagedShellPath $resolvedProfile)
}

function Invoke-AgentLocalCiUninstall {
    param([AllowNull()][string]$Home)
    $root = Assert-AgentLocalCiPathIsNarrow $(if ([string]::IsNullOrWhiteSpace($Home)) { Get-AgentLocalCiDefaultHome } else { $Home })
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return [pscustomobject]@{ Uninstalled = $false; Reason = "not installed"; InstallRoot = $root } }
    Assert-AgentLocalCiNoReparseAncestor $root
    $currentPath = Join-Path $root "current.json"
    $current = Read-AgentLocalCiJsonFile $currentPath
    if (
        $null -eq $current -or
        [string]$current.product -cne "AgentLocalCI" -or
        [int]$current.schema_version -ne 1 -or
        [string]$current.identity -cnotmatch '^[0-9a-f]{20}$'
    ) { Throw-AgentLocalCi -Message "Install root lacks a valid AgentLocalCI ownership manifest" -ExitCode 4 }
    $controller = Get-AgentLocalCiSafeFullPath ([string]$current.controller_root)
    if (-not (Test-AgentLocalCiPathContained $controller $root)) { Throw-AgentLocalCi -Message "Installed controller escaped the install root" -ExitCode 4 }
    $bin = Join-Path $root "bin"
    $profilePath = if ($null -ne $current.PSObject.Properties["path_profile"]) { [string]$current.path_profile } else { $null }
    Remove-AgentLocalCiBinFromUserPath $bin $profilePath
    $backup = "$root.uninstalled-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    if (Test-Path -LiteralPath $backup) { Throw-AgentLocalCi -Message "Uninstall backup path already exists" -ExitCode 4 }

    if ((Get-AgentLocalCiHostPlatform) -cne "windows") {
        Move-Item -LiteralPath $root -Destination $backup
        return [pscustomobject]@{
            Uninstalled = $true
            Backup = $backup
            ReportsPreserved = $true
            RestartShell = $true
            Restore = "Rename the backup to the original install root and restore its managed PATH block."
        }
    }

    [IO.Directory]::CreateDirectory($backup) | Out-Null
    foreach ($child in @(Get-ChildItem -LiteralPath $root -Force)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-AgentLocalCi -Message "Install root contains a reparse point; uninstall refused" -ExitCode 4 }
        $destination = Join-Path $backup $child.Name
        if ($child.Name -ceq "bin") { Copy-Item -LiteralPath $child.FullName -Destination $destination -Recurse }
        else { Move-Item -LiteralPath $child.FullName -Destination $destination }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $backup "current.json") -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $backup "controller") -PathType Container)) {
        Throw-AgentLocalCi -Message "Uninstall backup verification failed" -ExitCode 3
    }
    $tombstone = Join-Path $root "UNINSTALLED.txt"
    [IO.File]::WriteAllText($tombstone, "AgentLocalCI was uninstalled. The active command shims remain only so the invoking Windows batch process can exit safely.`r`nBackup: $backup`r`n", [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Uninstalled = $true
        Backup = $backup
        ReportsPreserved = $true
        TombstoneRoot = $root
        RestartShell = $true
        Restore = "Close shells using the old command, remove the tombstone root, rename the backup to the original install root, and re-add its bin directory to user PATH."
    }
}

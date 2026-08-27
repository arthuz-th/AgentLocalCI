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
    if (Test-Path -LiteralPath (Join-Path $context.RepositoryRoot "package-lock.json") -PathType Leaf) {
        $pipeline = Get-AgentLocalCiDefaultPipelineObject
        $pipeline.project.name = $projectName
    }
    elseif (Test-Path -LiteralPath (Join-Path $context.RepositoryRoot "gradlew") -PathType Leaf) {
        $pipeline = [ordered]@{
            schema_version = 1
            project = [ordered]@{ name = $projectName }
            default_profile = "standard"
            dependency_hosts = @("dl.google.com", "downloads.gradle.org", "github.com", "github-releases.githubusercontent.com", "maven.google.com", "objects.githubusercontent.com", "plugins.gradle.org", "plugins-artifacts.gradle.org", "release-assets.githubusercontent.com", "repo.maven.apache.org", "services.gradle.org")
            environment = [ordered]@{}
            dependencies = [ordered]@{ gradle = [ordered]@{ working_directory = "."; wrapper = "gradlew" } }
            profiles = [ordered]@{
                standard = [ordered]@{
                    description = "Repository-defined Gradle acceptance profile"
                    acceptance = $true
                    gaps = @("Emulators, hardware devices, hosted services, and deployment are outside this offline profile.")
                    stages = @([ordered]@{ id = "gradle-check"; command = @("./gradlew", "check"); working_directory = "."; needs = @("gradle"); timeout_seconds = 1800 })
                }
            }
        }
    }
    else {
        $pipeline = [ordered]@{
            schema_version = 1
            project = [ordered]@{ name = $projectName }
            default_profile = "diagnostic"
            dependency_hosts = @()
            environment = [ordered]@{}
            dependencies = [ordered]@{}
            profiles = [ordered]@{
                diagnostic = [ordered]@{
                    description = "Safe starter profile; replace with repository-specific checks before using as acceptance evidence"
                    acceptance = $false
                    gaps = @("No repository-specific test, lint, or build command is configured.")
                    stages = @([ordered]@{ id = "source-present"; command = @("/usr/bin/test", "-f", ".agentlocalci/pipeline.yml"); working_directory = "."; needs = @(); timeout_seconds = 300 })
                }
            }
        }
    }
    $pipelineObject = $pipeline | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
    [void](Assert-AgentLocalCiPipeline $pipelineObject $context.Policy $context.RepositoryRoot)
    $directory = Split-Path -Parent $path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    Assert-AgentLocalCiNoReparseAncestor $directory
    [IO.File]::WriteAllText($path, ($pipelineObject | ConvertTo-Json -Depth 50), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Created = $script:AgentLocalCiPipelinePath; Project = $projectName; DefaultProfile = [string]$pipelineObject.default_profile; Next = "Review, commit, and run using its exact 40-character commit SHA." }
}

function Remove-AgentLocalCiBinFromUserPath {
    param([Parameter(Mandatory = $true)][string]$BinPath)
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $normalized = [IO.Path]::GetFullPath($BinPath).TrimEnd([char[]]@('\', '/'))
    $kept = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Where-Object {
        try { -not ([IO.Path]::GetFullPath($_).TrimEnd([char[]]@('\', '/')).Equals($normalized, [StringComparison]::OrdinalIgnoreCase)) }
        catch { $true }
    })
    [Environment]::SetEnvironmentVariable("Path", ($kept -join ';'), "User")
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
    Remove-AgentLocalCiBinFromUserPath $bin
    $backup = "$root.uninstalled-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    if (Test-Path -LiteralPath $backup) { Throw-AgentLocalCi -Message "Uninstall backup path already exists" -ExitCode 4 }
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
    [IO.File]::WriteAllText($tombstone, "AgentLocalCI was uninstalled. The active command shims remain only so the invoking Windows batch process can exit safely. Reinstall over this directory or delete it after closing the current shell.`r`nBackup: $backup`r`n", [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Uninstalled = $true
        Backup = $backup
        ReportsPreserved = $true
        TombstoneRoot = $root
        Restore = "Close shells using the old command, remove the tombstone root, rename the backup to the original install root, and re-add its bin directory to user PATH."
    }
}

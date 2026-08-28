function Get-AgentLocalCiExactHead {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $result = Invoke-AgentLocalCiGit $RepositoryRoot @("rev-parse", "--verify", "HEAD^{commit}")
    $sha = ($result.Lines | Select-Object -First 1).Trim()
    if ($sha -cnotmatch '^[0-9a-f]{40}$') { Throw-AgentLocalCi -Message "Git did not return an exact lowercase commit SHA for HEAD" -ExitCode 3 }
    return Resolve-AgentLocalCiCommit $RepositoryRoot $sha
}

function Get-AgentLocalCiWorkingTreeChanges {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $result = Invoke-AgentLocalCiGit $RepositoryRoot @("status", "--porcelain=v1", "--untracked-files=all")
    return @($result.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Assert-AgentLocalCiWorkingTreeClean {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $changes = @(Get-AgentLocalCiWorkingTreeChanges $RepositoryRoot)
    if ($changes.Count -eq 0) { return }
    $preview = @($changes | Select-Object -First 8 | ForEach-Object { ConvertTo-AgentLocalCiSafeDisplayText ([string]$_) 240 }) -join "; "
    Throw-AgentLocalCi -Message "AgentLocalCI checks committed code only. Commit, stash, or discard the current working-tree changes, then run 'agentlocalci check' again. Changes: $preview" -ExitCode 2
}

function Commit-AgentLocalCiGeneratedConfiguration {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $changes = @(Get-AgentLocalCiWorkingTreeChanges $RepositoryRoot)
    $normalized = @($changes | ForEach-Object { ([string]$_).Replace([char]92, '/') })
    $allowed = @("?? .agentlocalci/pipeline.yml")
    if ($normalized.Count -ne 1 -or $allowed -cnotcontains $normalized[0]) {
        Throw-AgentLocalCi -Message "--commit is intentionally narrow and will only commit a newly generated .agentlocalci/pipeline.yml. Commit or clean all other changes first." -ExitCode 4
    }
    [void](Invoke-AgentLocalCiGit $RepositoryRoot @("add", "--", $script:AgentLocalCiPipelinePath))
    $staged = Invoke-AgentLocalCiGit $RepositoryRoot @("diff", "--cached", "--name-only", "--diff-filter=ACMRTUXB")
    $stagedPaths = @($staged.Lines | Where-Object { $_ })
    if ($stagedPaths.Count -ne 1 -or [string]$stagedPaths[0] -cne $script:AgentLocalCiPipelinePath) {
        Throw-AgentLocalCi -Message "AgentLocalCI refused to create a commit because the staged set was not exactly .agentlocalci/pipeline.yml" -ExitCode 4
    }
    [void](Invoke-AgentLocalCiGit $RepositoryRoot @("commit", "--no-gpg-sign", "-m", "ci: add AgentLocalCI configuration", "--", $script:AgentLocalCiPipelinePath))
    Assert-AgentLocalCiWorkingTreeClean $RepositoryRoot
    return Get-AgentLocalCiExactHead $RepositoryRoot
}

function Invoke-AgentLocalCiCheck {
    param(
        [AllowNull()][string]$Home,
        [AllowNull()][string]$RepositoryRoot,
        [AllowNull()][string]$PolicyPath,
        [AllowNull()][string]$ProfileName,
        [ValidateRange(0, 86400)][int]$WaitSeconds = 0,
        [switch]$OpenReport
    )
    $root = Get-AgentLocalCiRepositoryRoot $RepositoryRoot
    Assert-AgentLocalCiWorkingTreeClean $root
    $sha = Get-AgentLocalCiExactHead $root
    $run = Invoke-AgentLocalCiRun $Home $root $PolicyPath $sha $ProfileName $WaitSeconds
    if ($OpenReport -and (Test-Path -LiteralPath $run.HtmlPath -PathType Leaf)) { [void](Open-AgentLocalCiPath $run.HtmlPath) }
    return $run
}

function Invoke-AgentLocalCiQuickstart {
    param(
        [AllowNull()][string]$Home,
        [AllowNull()][string]$RepositoryRoot,
        [AllowNull()][string]$PolicyPath,
        [AllowNull()][string]$ProfileName,
        [ValidateRange(0, 86400)][int]$WaitSeconds = 0,
        [switch]$CommitConfiguration,
        [switch]$OpenReport
    )
    $root = Get-AgentLocalCiRepositoryRoot $RepositoryRoot
    $doctor = Invoke-AgentLocalCiDoctor $Home $root $PolicyPath -BuildImage
    if (-not $doctor.Passed) {
        $details = @($doctor.Checks | Where-Object { -not $_.passed } | ForEach-Object {
            $fix = if ([string]::IsNullOrWhiteSpace([string]$_.fix)) { "" } else { " Fix: $($_.fix)" }
            "$($_.name): $($_.detail).$fix"
        }) -join " "
        Throw-AgentLocalCi -Message "AgentLocalCI setup checks failed. $details" -ExitCode 3
    }

    $pipelinePath = Resolve-AgentLocalCiRelativePath $root $script:AgentLocalCiPipelinePath
    $setup = $null
    $committedSha = $null
    if (-not (Test-Path -LiteralPath $pipelinePath -PathType Leaf)) {
        if ($CommitConfiguration) { Assert-AgentLocalCiWorkingTreeClean $root }
        $setup = Initialize-AgentLocalCiRepository $Home $root $PolicyPath
        if (-not $CommitConfiguration) {
            return [pscustomobject]@{
                ExitCode = 0
                Result = "SetupCreated"
                Ran = $false
                Repository = $root
                Setup = $setup
                Next = "Review and commit .agentlocalci/pipeline.yml, then run 'agentlocalci check'. To let AgentLocalCI create only that commit and continue automatically, run 'agentlocalci quickstart --commit'."
            }
        }
        $committedSha = Commit-AgentLocalCiGeneratedConfiguration $root
    }

    $run = Invoke-AgentLocalCiCheck $Home $root $PolicyPath $ProfileName $WaitSeconds -OpenReport:$OpenReport
    return [pscustomobject]@{
        ExitCode = [int]$run.ExitCode
        Result = [string]$run.Result
        Ran = $true
        Repository = $root
        Setup = $setup
        ConfigurationCommit = $committedSha
        Run = $run
    }
}

function Get-AgentLocalCiWhyInformation {
    return [pscustomobject]@{
        Headline = "Use your own machine for exact-commit checks before code leaves it."
        BestFor = @(
            "Private repositories where routine hosted CI minutes or runner charges matter.",
            "Fast pre-push feedback without waiting in a hosted queue.",
            "Repositories whose source or test output should remain on the developer machine.",
            "Teams that want one reproducible exact-commit report before opening or merging a pull request.",
            "Windows, macOS, and Linux developers who want the same locked-down Linux validation boundary."
        )
        Advantages = @(
            "The easy 'check' command resolves the current exact commit automatically and refuses dirty working trees.",
            "Validation runs with network=none after narrowly allowlisted dependency preparation.",
            "The host repository, Docker socket, personal files, and credentials are not mounted or forwarded.",
            "Every run produces JSON, Markdown, and a self-contained HTML report.",
            "Optional pre-push enforcement is local, explicit, removable, and refuses to overwrite an unowned hook.",
            "Cleanup is ownership-verified and fails closed instead of broadly deleting Docker resources."
        )
        KeepGitHubActionsFor = @(
            "Required pull-request status checks visible to every collaborator.",
            "Hosted operating-system and version matrices that your local machine cannot provide.",
            "Deployment, release publishing, cloud credentials, and organization-wide automation.",
            "Independent verification on infrastructure that is not controlled by the developer submitting the code."
        )
        RecommendedPattern = "Run AgentLocalCI locally for every commit or push, then keep a smaller hosted workflow for shared status checks, platform matrices, releases, and deployment."
    }
}

function Get-AgentLocalCiWhyText {
    $why = Get-AgentLocalCiWhyInformation
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("Why AgentLocalCI?")
    $lines.Add("")
    $lines.Add($why.Headline)
    $lines.Add("")
    $lines.Add("Good reasons to use it:")
    foreach ($item in $why.BestFor) { $lines.Add("  - $item") }
    $lines.Add("")
    $lines.Add("What it adds:")
    foreach ($item in $why.Advantages) { $lines.Add("  - $item") }
    $lines.Add("")
    $lines.Add("Keep GitHub Actions or another hosted CI for:")
    foreach ($item in $why.KeepGitHubActionsFor) { $lines.Add("  - $item") }
    $lines.Add("")
    $lines.Add("Recommended: $($why.RecommendedPattern)")
    return $lines -join "`n"
}

function Invoke-AgentLocalCiMetadataGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $nullDevice = Get-AgentLocalCiNullDevice
    $nativeArguments = @(
        "--no-pager", "--no-replace-objects", "-c", "credential.helper=", "-C", $RepositoryRoot
    ) + @($Arguments)
    return Invoke-AgentLocalCiNative -FilePath (Get-AgentLocalCiGitPath) -Arguments $nativeArguments -AllowFailure:$AllowFailure -Environment @{
        GIT_CONFIG_NOSYSTEM = "1"
        GIT_CONFIG_GLOBAL = $nullDevice
        GIT_TERMINAL_PROMPT = "0"
        GIT_OPTIONAL_LOCKS = "0"
        GIT_ASKPASS = ""
        SSH_ASKPASS = ""
    } -RemoveEnvironmentPrefixes @("GIT_", "SSH_ASKPASS")
}

function Get-AgentLocalCiPrePushHookPath {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $gitDirectory = Join-Path $RepositoryRoot ".git"
    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) {
        Throw-AgentLocalCi -Message "AgentLocalCI hook management supports standard clones only. Linked worktrees or repositories with a .git indirection must integrate 'agentlocalci check' manually." -ExitCode 4
    }
    $gitItem = Get-Item -LiteralPath $gitDirectory -Force
    if (($gitItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-AgentLocalCi -Message "AgentLocalCI refuses a symbolic-link or junction .git directory for hook management" -ExitCode 4
    }
    $customHooks = Invoke-AgentLocalCiMetadataGit $RepositoryRoot @("config", "--local", "--get", "core.hooksPath") -AllowFailure
    if ($customHooks.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($customHooks.Text)) {
        Throw-AgentLocalCi -Message "This repository configures core.hooksPath. AgentLocalCI left it unchanged; integrate 'agentlocalci check' into that hook path manually." -ExitCode 4
    }
    $parent = Join-Path $gitDirectory "hooks"
    Assert-AgentLocalCiNoReparseAncestor $gitDirectory
    if (Test-Path -LiteralPath $parent) {
        $parentItem = Get-Item -LiteralPath $parent -Force
        if (-not $parentItem.PSIsContainer -or ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-AgentLocalCi -Message "The Git hooks path is not a normal owned directory" -ExitCode 4
        }
    }
    return [IO.Path]::GetFullPath((Join-Path $parent "pre-push"))
}

function Get-AgentLocalCiHookState {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $path = Get-AgentLocalCiPrePushHookPath $RepositoryRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Installed = $false; Owned = $false; Path = $path; Profile = "" }
    }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Length -gt 128KB) { return [pscustomobject]@{ Installed = $true; Owned = $false; Path = $path; Profile = "" } }
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $owned = $text.Contains("# AgentLocalCI managed pre-push hook v1", [StringComparison]::Ordinal)
    $profile = if ($text -match '(?m)^# AgentLocalCI profile: ([a-z][a-z0-9-]{0,63})$') { $Matches[1] } else { "" }
    return [pscustomobject]@{ Installed = $true; Owned = $owned; Path = $path; Profile = $profile }
}

function Install-AgentLocalCiPrePushHook {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [AllowNull()][string]$ProfileName
    )
    $root = Get-AgentLocalCiRepositoryRoot $RepositoryRoot
    $profile = if ([string]::IsNullOrWhiteSpace($ProfileName)) { "standard" } else { $ProfileName.ToLowerInvariant() }
    if ($profile -cnotmatch '^[a-z][a-z0-9-]{0,63}$') { Throw-AgentLocalCi -Message "Invalid hook profile '$profile'" -ExitCode 2 }
    $state = Get-AgentLocalCiHookState $root
    if ($state.Installed -and -not $state.Owned) {
        Throw-AgentLocalCi -Message "A pre-push hook already exists and is not owned by AgentLocalCI. It was left unchanged." -ExitCode 4
    }
    $directory = Split-Path -Parent $state.Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    Assert-AgentLocalCiNoReparseAncestor $directory
    $template = @'
#!/bin/sh
# AgentLocalCI managed pre-push hook v1
# AgentLocalCI profile: __PROFILE__
set -eu
repo="$(git rev-parse --show-toplevel)"
if ! command -v agentlocalci >/dev/null 2>&1; then
  echo "AgentLocalCI: command not found. Reinstall AgentLocalCI or remove this owned hook with agentlocalci hook remove." >&2
  exit 2
fi
agentlocalci check --repository "$repo" --profile "__PROFILE__"
'@
    $content = $template.Replace("__PROFILE__", $profile, [StringComparison]::Ordinal)
    [IO.File]::WriteAllText($state.Path, $content.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    if ((Get-AgentLocalCiHostPlatform) -cne "windows") {
        try { [IO.File]::SetUnixFileMode($state.Path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute) }
        catch { Throw-AgentLocalCi -Message "The pre-push hook was written but could not be marked executable" -ExitCode 3 }
    }
    $verified = Get-AgentLocalCiHookState $root
    if (-not $verified.Owned -or [string]$verified.Profile -cne $profile) { Throw-AgentLocalCi -Message "Pre-push hook verification failed" -ExitCode 3 }
    return $verified
}

function Remove-AgentLocalCiPrePushHook {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $root = Get-AgentLocalCiRepositoryRoot $RepositoryRoot
    $state = Get-AgentLocalCiHookState $root
    if (-not $state.Installed) { return [pscustomobject]@{ Removed = $false; Reason = "not installed"; Path = $state.Path } }
    if (-not $state.Owned) { Throw-AgentLocalCi -Message "The existing pre-push hook is not owned by AgentLocalCI and was left unchanged" -ExitCode 4 }
    Remove-Item -LiteralPath $state.Path -Force
    if (Test-Path -LiteralPath $state.Path) { Throw-AgentLocalCi -Message "Pre-push hook absence could not be proven" -ExitCode 3 }
    return [pscustomobject]@{ Removed = $true; Path = $state.Path }
}

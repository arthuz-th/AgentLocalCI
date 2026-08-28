function Invoke-AgentLocalCiGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [switch]$AllowFailure,
        [AllowNull()][string]$StandardInputText
    )
    $git = Get-AgentLocalCiGitPath
    $nullDevice = Get-AgentLocalCiNullDevice
    $base = @(
        "--no-pager", "--no-replace-objects",
        "-c", "core.hooksPath=$nullDevice",
        "-c", "core.attributesFile=$nullDevice",
        "-c", "core.fsmonitor=false",
        "-c", "credential.helper=",
        "-C", $RepositoryRoot
    )
    return Invoke-AgentLocalCiNative -FilePath $git -Arguments @($base + $Arguments) -AllowFailure:$AllowFailure -StandardInputText $StandardInputText -Environment @{
        GIT_CONFIG_NOSYSTEM = "1"
        GIT_CONFIG_GLOBAL = $nullDevice
        GIT_TERMINAL_PROMPT = "0"
        GIT_OPTIONAL_LOCKS = "0"
        GIT_ASKPASS = ""
        SSH_ASKPASS = ""
    } -RemoveEnvironmentPrefixes @("GIT_", "SSH_ASKPASS")
}

function Resolve-AgentLocalCiCommit {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Revision
    )
    if ($Revision -cnotmatch '^[0-9a-f]{40}$') { Throw-AgentLocalCi -Message "run requires an exact lowercase 40-character local commit SHA" -ExitCode 2 }
    $result = Invoke-AgentLocalCiGit $RepositoryRoot @("rev-parse", "--verify", "--end-of-options", "$Revision^{commit}") -AllowFailure
    if ($result.ExitCode -ne 0 -or $result.Lines.Count -ne 1 -or $result.Lines[0] -cne $Revision) { Throw-AgentLocalCi -Message "Exact commit is unavailable in the local object store: $Revision" -ExitCode 2 }
    return $Revision
}

function Get-AgentLocalCiCommitTree {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Sha
    )
    $result = Invoke-AgentLocalCiGit $RepositoryRoot @("rev-parse", "--verify", "$Sha^{tree}")
    $tree = ($result.Lines | Select-Object -First 1)
    if ($tree -cnotmatch '^[0-9a-f]{40}$') { Throw-AgentLocalCi -Message "Git returned an invalid tree identity" -ExitCode 3 }
    return $tree
}

function Get-AgentLocalCiTreeEntry {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Sha,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    if (-not (Test-AgentLocalCiSafeRelativePath $RelativePath)) { Throw-AgentLocalCi -Message "Unsafe Git tree path '$RelativePath'" -ExitCode 2 }
    $path = $RelativePath.Replace('\', '/')
    $result = Invoke-AgentLocalCiGit $RepositoryRoot @("ls-tree", "-z", "--full-tree", $Sha, "--", $path) -AllowFailure
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrEmpty($result.Stdout)) { return $null }
    $entries = @($result.Stdout -split [char]0 | Where-Object { $_ })
    if ($entries.Count -ne 1 -or $entries[0] -cnotmatch '^([0-9]{6}) (blob|tree) ([0-9a-f]{40})\t(.+)$') { Throw-AgentLocalCi -Message "Git returned an ambiguous tree entry for '$path'" -ExitCode 3 }
    return [pscustomobject]@{ mode = $Matches[1]; type = $Matches[2]; object = $Matches[3]; path = $Matches[4] }
}

function Read-AgentLocalCiPipelineFromCommit {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Sha
    )
    $entry = Get-AgentLocalCiTreeEntry $Context.RepositoryRoot $Sha $script:AgentLocalCiPipelinePath
    if ($null -eq $entry) { Throw-AgentLocalCi -Message "Commit $Sha does not contain $script:AgentLocalCiPipelinePath" -ExitCode 2 }
    if ($entry.type -cne "blob" -or $entry.mode -notin @("100644", "100755")) { Throw-AgentLocalCi -Message "$script:AgentLocalCiPipelinePath must be a regular Git blob, not a symlink or submodule" -ExitCode 4 }
    $blob = Invoke-AgentLocalCiGit $Context.RepositoryRoot @("cat-file", "blob", $entry.object)
    if ($blob.Stdout.Length -gt 1MB) { Throw-AgentLocalCi -Message "Pipeline document exceeds the 1 MiB bound" -ExitCode 2 }
    $pipeline = ConvertFrom-AgentLocalCiJsonYaml -Text $blob.Stdout -SourceName "$Sha`:$script:AgentLocalCiPipelinePath"
    return Assert-AgentLocalCiPipeline $pipeline $Context.Policy $Context.RepositoryRoot
}

function New-AgentLocalCiProvenancePack {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Sha,
        [Parameter(Mandatory = $true)][string]$RunDirectory
    )
    $tree = Get-AgentLocalCiCommitTree $Context.RepositoryRoot $Sha
    $list = Invoke-AgentLocalCiGit $Context.RepositoryRoot @("ls-tree", "-r", "-t", "--full-tree", $Sha)
    $objects = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$objects.Add($Sha)
    [void]$objects.Add($tree)
    foreach ($line in $list.Lines) {
        if ($line -cnotmatch '^([0-9]{6}) (blob|tree|commit) ([0-9a-f]{40})\t(.+)$') { Throw-AgentLocalCi -Message "Git returned an invalid recursive tree listing" -ExitCode 3 }
        $mode = $Matches[1]
        $type = $Matches[2]
        $objectId = $Matches[3]
        $entryPath = $Matches[4]
        if ($entryPath -match '(?i)(^|/)\.git(?:/|$)') {
            Throw-AgentLocalCi -Message "The selected exact tree contains reserved Git metadata path content" -ExitCode 4
        }
        if ($mode -ceq "160000" -or $type -ceq "commit") {
            Throw-AgentLocalCi -Message "Git submodules are not supported in AgentLocalCI 0.2; the selected exact tree contains a gitlink" -ExitCode 4
        }
        if ($mode -notin @("040000", "100644", "100755", "120000") -or $type -notin @("blob", "tree")) {
            Throw-AgentLocalCi -Message "Git returned an unsupported tree entry mode or type" -ExitCode 4
        }
        [void]$objects.Add($objectId)
    }
    $packRoot = Join-Path $RunDirectory "provenance"
    [IO.Directory]::CreateDirectory($packRoot) | Out-Null
    $prefix = Join-Path $packRoot "exact-tree"
    $inputText = ((@($objects) | Sort-Object) -join "`n") + "`n"
    $pack = Invoke-AgentLocalCiGit $Context.RepositoryRoot @("pack-objects", "--compression=9", $prefix) -StandardInputText $inputText
    $packId = ($pack.Lines | Select-Object -Last 1).Trim()
    if ($packId -cnotmatch '^[0-9a-f]{40}$') { Throw-AgentLocalCi -Message "Git pack-objects returned an invalid identity" -ExitCode 3 }
    $packPath = "$prefix-$packId.pack"
    if (-not (Test-Path -LiteralPath $packPath -PathType Leaf)) { Throw-AgentLocalCi -Message "Exact-tree pack was not created" -ExitCode 3 }
    $indexResult = Invoke-AgentLocalCiNative -FilePath (Get-AgentLocalCiGitPath) -Arguments @("index-pack", $packPath)
    $indexPath = $packPath -replace '\.pack$', '.idx'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { Throw-AgentLocalCi -Message "Exact-tree pack index was not created" -ExitCode 3 }
    $verify = Invoke-AgentLocalCiNative -FilePath (Get-AgentLocalCiGitPath) -Arguments @("verify-pack", "-v", $indexPath)
    $packedObjectIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $verify.Lines) {
        if ($line -cmatch '^([0-9a-f]{40})\s') { [void]$packedObjectIds.Add($Matches[1]) }
    }
    foreach ($objectId in $objects) { if (-not $packedObjectIds.Contains($objectId)) { Throw-AgentLocalCi -Message "Exact-tree pack omitted a required object" -ExitCode 3 } }
    if ($packedObjectIds.Count -ne $objects.Count) { Throw-AgentLocalCi -Message "Exact-tree pack contains an object outside the selected commit tree" -ExitCode 4 }
    foreach ($packedObjectId in $packedObjectIds) { if (-not $objects.Contains($packedObjectId)) { Throw-AgentLocalCi -Message "Exact-tree pack contains an unrelated object" -ExitCode 4 } }
    $parentResult = Invoke-AgentLocalCiGit $Context.RepositoryRoot @("rev-list", "--parents", "-n", "1", $Sha)
    $parentIds = @((($parentResult.Lines | Select-Object -First 1) -split ' ') | Select-Object -Skip 1)
    foreach ($parentId in $parentIds) { if ($packedObjectIds.Contains($parentId)) { Throw-AgentLocalCi -Message "Exact-tree pack unexpectedly contains parent history" -ExitCode 4 } }
    return [pscustomobject]@{
        Path = $packPath
        IndexPath = $indexPath
        Commit = $Sha
        Tree = $tree
        ObjectCount = $objects.Count
        PackSha256 = (Get-FileHash -LiteralPath $packPath -Algorithm SHA256).Hash.ToLowerInvariant()
        HistoryIncluded = $false
        HostCheckoutPerformed = $false
        RemoteMetadataIncluded = $false
    }
}

function New-AgentLocalCiSourceVolumeFromPack {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Image,
        [Parameter(Mandatory = $true)][object]$Provenance,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$NamePrefix,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources,
        [Parameter(Mandatory = $true)][string]$LogDirectory
    )
    $volume = "$NamePrefix-src"
    $container = "$NamePrefix-seed"
    New-AgentLocalCiDockerVolume $volume $RunId "$NamePrefix-source" $Resources | Out-Null
    $arguments = New-AgentLocalCiContainerBaseArguments $Context $container $RunId "$NamePrefix-seed" "none"
    $command = 'set -euo pipefail; mkdir /workspace/repo; git -C /workspace/repo init -q; git -C /workspace/repo config core.hooksPath /dev/null; git -C /workspace/repo config core.attributesFile /dev/null; git -C /workspace/repo config core.autocrlf false; git -C /workspace/repo config core.safecrlf true; mkdir -p /workspace/repo/.git/info; printf "%s\n" "* -text -filter -ident -working-tree-encoding" > /workspace/repo/.git/info/attributes; git -C /workspace/repo index-pack --stdin < /workspace/source.pack >/dev/null; git -C /workspace/repo cat-file -e "$AGENTLOCALCI_TARGET_SHA^{commit}"; git -C /workspace/repo cat-file -e "$AGENTLOCALCI_TARGET_TREE^{tree}"; printf "%s\n" "$AGENTLOCALCI_TARGET_SHA" > /workspace/repo/.git/shallow; printf "%s\n" "$AGENTLOCALCI_TARGET_SHA" > /workspace/repo/.git/HEAD; git -C /workspace/repo read-tree "$AGENTLOCALCI_TARGET_SHA"; test "$(git -C /workspace/repo write-tree)" = "$AGENTLOCALCI_TARGET_TREE"; git -C /workspace/repo checkout-index -a -f; test "$(git -C /workspace/repo rev-parse HEAD)" = "$AGENTLOCALCI_TARGET_SHA"; test -z "$(git -C /workspace/repo status --porcelain --untracked-files=all)"; ! git -C /workspace/repo cat-file -e "$AGENTLOCALCI_TARGET_SHA^" 2>/dev/null; printf "%s\n" "$AGENTLOCALCI_TARGET_SHA" > /workspace/.agentlocalci-commit; printf "%s\n" "$AGENTLOCALCI_TARGET_TREE" > /workspace/.agentlocalci-tree; chmod 0444 /workspace/.agentlocalci-commit /workspace/.agentlocalci-tree; rm -rf -- /workspace/repo/.git; test ! -e /workspace/repo/.git; rm -f -- /workspace/source.pack'
    $arguments += @(
        "--mount", "type=volume,source=$volume,target=/workspace",
        "--workdir", "/workspace",
        "--env", "AGENTLOCALCI_TARGET_SHA=$($Provenance.Commit)",
        "--env", "AGENTLOCALCI_TARGET_TREE=$($Provenance.Tree)",
        $Image.Id, "/bin/bash", "-c", $command
    )
    New-AgentLocalCiTrackedContainer $arguments $container $RunId "$NamePrefix-seed" $Resources | Out-Null
    Invoke-AgentLocalCiDocker @("container", "cp", $Provenance.Path, "${container}:/workspace/source.pack") | Out-Null
    Assert-AgentLocalCiRuntimeContainer $container $Image.Id @($volume) "none"
    $result = Start-AgentLocalCiContainerWithTimeout $container (Join-Path $LogDirectory "$container.stdout.log") (Join-Path $LogDirectory "$container.stderr.log") 900 ([int]$Context.Policy.resources.output_limit_mib)
    if ($result.ExitCode -ne 0) { Throw-AgentLocalCi -Message "Exact-tree source materialization failed with exit code $($result.ExitCode)" -ExitCode 3 }
    return $volume
}

function Copy-AgentLocalCiVolume {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Image,
        [Parameter(Mandatory = $true)][string]$SourceVolume,
        [Parameter(Mandatory = $true)][string]$DestinationVolume,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$NamePrefix,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources,
        [Parameter(Mandatory = $true)][string]$LogDirectory
    )
    $container = "$NamePrefix-copy"
    $arguments = New-AgentLocalCiContainerBaseArguments $Context $container $RunId "$NamePrefix-copy" "none"
    $arguments += @(
        "--mount", "type=volume,source=$SourceVolume,target=/from,readonly",
        "--mount", "type=volume,source=$DestinationVolume,target=/to",
        $Image.Id, "/bin/bash", "-c", "set -euo pipefail; cp -a /from/. /to/"
    )
    New-AgentLocalCiTrackedContainer $arguments $container $RunId "$NamePrefix-copy" $Resources | Out-Null
    Assert-AgentLocalCiRuntimeContainer $container $Image.Id @($SourceVolume, $DestinationVolume) "none"
    $result = Start-AgentLocalCiContainerWithTimeout $container (Join-Path $LogDirectory "$container.stdout.log") (Join-Path $LogDirectory "$container.stderr.log") 1800 ([int]$Context.Policy.resources.output_limit_mib)
    if ($result.ExitCode -ne 0) { Throw-AgentLocalCi -Message "Run-private volume copy failed with exit code $($result.ExitCode)" -ExitCode 3 }
}

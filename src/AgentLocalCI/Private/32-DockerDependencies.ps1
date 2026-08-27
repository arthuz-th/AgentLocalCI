function Get-AgentLocalCiDockerNetworkGateways {
    param([Parameter(Mandatory = $true)][object]$NetworkInspection)
    $gateways = [Collections.Generic.List[string]]::new()
    $ipamProperty = $NetworkInspection.PSObject.Properties['IPAM']
    if ($null -eq $ipamProperty -or $null -eq $ipamProperty.Value) { return $gateways.ToArray() }
    $configProperty = $ipamProperty.Value.PSObject.Properties['Config']
    if ($null -eq $configProperty -or $null -eq $configProperty.Value) { return $gateways.ToArray() }
    foreach ($configuration in @($configProperty.Value)) {
        if ($null -eq $configuration) { continue }
        $gatewayProperty = $configuration.PSObject.Properties['Gateway']
        if ($null -eq $gatewayProperty -or [string]::IsNullOrWhiteSpace([string]$gatewayProperty.Value)) { continue }
        $gateway = [string]$gatewayProperty.Value
        if ($gateway -notmatch '^[0-9a-fA-F:.]+$') { Throw-AgentLocalCi -Message "Docker returned an unsafe dependency-network gateway" -ExitCode 4 }
        $gateways.Add($gateway)
    }
    return $gateways.ToArray()
}

function Start-AgentLocalCiDependencyProxy {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Image,
        [Parameter(Mandatory = $true)][object]$Pipeline,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$NamePrefix,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources,
        [Parameter(Mandatory = $true)][string]$LogDirectory
    )
    if (@($Pipeline.dependency_hosts).Count -eq 0) { Throw-AgentLocalCi -Message "Dependency preparation requires at least one policy-approved HTTPS host" -ExitCode 2 }
    $network = New-AgentLocalCiDockerNetwork "$NamePrefix-net" $RunId $Resources
    $proxy = "$NamePrefix-proxy"
    $alias = "dependency-proxy"
    $allowedHosts = (@($Pipeline.dependency_hosts) | Sort-Object) -join ','
    $arguments = New-AgentLocalCiContainerBaseArguments $Context $proxy $RunId "dependency-proxy" "bridge"
    $arguments += @("--env", "AGENTLOCALCI_ALLOWED_HOSTS=$allowedHosts", $Image.Id, "node", "/opt/agentlocalci/proxy.mjs")
    New-AgentLocalCiTrackedContainer $arguments $proxy $RunId "dependency-proxy" $Resources | Out-Null
    Invoke-AgentLocalCiDocker @("network", "connect", "--alias", $alias, $network, $proxy) | Out-Null
    Assert-AgentLocalCiRuntimeContainer $proxy $Image.Id @() "bridge"
    $proxyInspection = ConvertFrom-AgentLocalCiSingleInspection (Invoke-AgentLocalCiDocker @("container", "inspect", $proxy)).Text "container"
    $attachedNetworks = @($proxyInspection.NetworkSettings.Networks.PSObject.Properties.Name)
    if ($attachedNetworks.Count -ne 2 -or $attachedNetworks -cnotcontains "bridge" -or $attachedNetworks -cnotcontains $network) {
        Throw-AgentLocalCi -Message "Dependency proxy is not attached to exactly the default egress bridge and the isolated run network" -ExitCode 4
    }
    Invoke-AgentLocalCiDocker @("container", "start", $proxy) | Out-Null
    $ready = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $health = Invoke-AgentLocalCiDocker @("container", "exec", $proxy, "node", "/opt/agentlocalci/proxy-health.mjs") -AllowFailure
        if ($health.ExitCode -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ready) { Throw-AgentLocalCi -Message "Dependency proxy did not become healthy within the bounded startup window" -ExitCode 3 }

    $networkInspection = ConvertFrom-AgentLocalCiSingleInspection (Invoke-AgentLocalCiDocker @("network", "inspect", $network)).Text "network"
    $gateways = @(Get-AgentLocalCiDockerNetworkGateways $networkInspection)
    $probe = "$NamePrefix-probe"
    $probeArguments = New-AgentLocalCiContainerBaseArguments $Context $probe $RunId "dependency-network-probe" $network
    $probeArguments += @($Image.Id, "node", "/opt/agentlocalci/network-probe.mjs", $alias, [string]$Pipeline.dependency_hosts[0]) + $gateways
    New-AgentLocalCiTrackedContainer $probeArguments $probe $RunId "dependency-network-probe" $Resources | Out-Null
    Assert-AgentLocalCiRuntimeContainer $probe $Image.Id @() $network
    $result = Start-AgentLocalCiContainerWithTimeout $probe (Join-Path $LogDirectory "$probe.stdout.log") (Join-Path $LogDirectory "$probe.stderr.log") 60 ([int]$Context.Policy.resources.output_limit_mib)
    if ($result.ExitCode -ne 0) { Throw-AgentLocalCi -Message "Dependency network boundary probe failed" -ExitCode 4 }
    return [pscustomobject]@{ Network = $network; ProxyContainer = $proxy; Alias = $alias; Uri = "http://${alias}:8080" }
}

function New-AgentLocalCiNpmSeed {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Image,
        [Parameter(Mandatory = $true)][object]$Pipeline,
        [Parameter(Mandatory = $true)][object]$Provenance,
        [Parameter(Mandatory = $true)][object]$Proxy,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$NamePrefix,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources,
        [Parameter(Mandatory = $true)][string]$LogDirectory
    )
    $source = New-AgentLocalCiSourceVolumeFromPack $Context $Image $Provenance $RunId "$NamePrefix-npm" $Resources $LogDirectory
    $cache = "$NamePrefix-npm-cache"
    New-AgentLocalCiDockerVolume $cache $RunId "npm-seed-cache" $Resources | Out-Null
    $container = "$NamePrefix-npm-fetch"
    $workdir = if ($Pipeline.dependencies.npm.working_directory -eq ".") { "/workspace/repo" } else { "/workspace/repo/" + ([string]$Pipeline.dependencies.npm.working_directory).TrimStart([char[]]@('.', '/')) }
    $arguments = New-AgentLocalCiContainerBaseArguments $Context $container $RunId "npm-dependency-fetch" $Proxy.Network
    $arguments += @(
        "--mount", "type=volume,source=$source,target=/workspace",
        "--mount", "type=volume,source=$cache,target=/npm-cache",
        "--workdir", $workdir,
        "--env", "HTTP_PROXY=$($Proxy.Uri)", "--env", "HTTPS_PROXY=$($Proxy.Uri)",
        "--env", "http_proxy=$($Proxy.Uri)", "--env", "https_proxy=$($Proxy.Uri)",
        "--env", "NO_PROXY=localhost,127.0.0.1,::1", "--env", "no_proxy=localhost,127.0.0.1,::1",
        "--env", "NPM_CONFIG_USERCONFIG=/tmp/npm-userconfig",
        "--env", "NPM_CONFIG_GLOBALCONFIG=/tmp/npm-globalconfig",
        "--env", "NPM_CONFIG_CACHE=/npm-cache",
        $Image.Id, "npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"
    )
    New-AgentLocalCiTrackedContainer $arguments $container $RunId "npm-dependency-fetch" $Resources | Out-Null
    Assert-AgentLocalCiRuntimeContainer $container $Image.Id @($source, $cache) $Proxy.Network
    $result = Start-AgentLocalCiContainerWithTimeout $container (Join-Path $LogDirectory "$container.stdout.log") (Join-Path $LogDirectory "$container.stderr.log") ([int]$Context.Policy.resources.run_timeout_seconds) ([int]$Context.Policy.resources.output_limit_mib)
    if ($result.ExitCode -ne 0) { Throw-AgentLocalCi -Message "npm dependency preparation failed with exit code $($result.ExitCode)" -ExitCode 1 }
    return $cache
}

function New-AgentLocalCiGradleSeed {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Image,
        [Parameter(Mandatory = $true)][object]$Pipeline,
        [Parameter(Mandatory = $true)][object]$Provenance,
        [Parameter(Mandatory = $true)][object]$Proxy,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$NamePrefix,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources,
        [Parameter(Mandatory = $true)][string]$LogDirectory
    )
    $source = New-AgentLocalCiSourceVolumeFromPack $Context $Image $Provenance $RunId "$NamePrefix-gradle" $Resources $LogDirectory
    $cache = "$NamePrefix-gradle-cache"
    New-AgentLocalCiDockerVolume $cache $RunId "gradle-seed-cache" $Resources | Out-Null
    $container = "$NamePrefix-gradle-fetch"
    $relativeWorkdir = [string]$Pipeline.dependencies.gradle.working_directory
    $workdir = if ($relativeWorkdir -eq ".") { "/workspace/repo" } else { "/workspace/repo/" + $relativeWorkdir.TrimStart('/') }
    $wrapper = if ([string]$Pipeline.dependencies.gradle.wrapper -eq ".") { "$workdir/gradlew" } else { "$workdir/" + ([string]$Pipeline.dependencies.gradle.wrapper).TrimStart([char[]]@('.', '/')) }
    $proxyUri = [Uri]$Proxy.Uri
    $javaOptions = "-Dhttps.proxyHost=$($proxyUri.Host) -Dhttps.proxyPort=$($proxyUri.Port) -Dhttp.proxyHost=$($proxyUri.Host) -Dhttp.proxyPort=$($proxyUri.Port)"
    $arguments = New-AgentLocalCiContainerBaseArguments $Context $container $RunId "gradle-dependency-fetch" $Proxy.Network
    $arguments += @(
        "--mount", "type=volume,source=$source,target=/workspace",
        "--mount", "type=volume,source=$cache,target=/gradle",
        "--workdir", $workdir,
        "--env", "HTTP_PROXY=$($Proxy.Uri)", "--env", "HTTPS_PROXY=$($Proxy.Uri)",
        "--env", "http_proxy=$($Proxy.Uri)", "--env", "https_proxy=$($Proxy.Uri)",
        "--env", "NO_PROXY=localhost,127.0.0.1,::1", "--env", "no_proxy=localhost,127.0.0.1,::1",
        "--env", "JAVA_TOOL_OPTIONS=$javaOptions", "--env", "GRADLE_USER_HOME=/gradle",
        $Image.Id, "/bin/bash", $wrapper,
        "--init-script", "/opt/agentlocalci/resolve-dependencies.gradle",
        "--no-daemon", "--console=plain", "--max-workers=$([int]$Context.Policy.resources.gradle_max_workers)", "help"
    )
    New-AgentLocalCiTrackedContainer $arguments $container $RunId "gradle-dependency-fetch" $Resources | Out-Null
    Assert-AgentLocalCiRuntimeContainer $container $Image.Id @($source, $cache) $Proxy.Network
    $result = Start-AgentLocalCiContainerWithTimeout $container (Join-Path $LogDirectory "$container.stdout.log") (Join-Path $LogDirectory "$container.stderr.log") ([int]$Context.Policy.resources.run_timeout_seconds) ([int]$Context.Policy.resources.output_limit_mib)
    if ($result.ExitCode -ne 0) { Throw-AgentLocalCi -Message "Gradle dependency preparation failed with exit code $($result.ExitCode)" -ExitCode 1 }
    return $cache
}

function Initialize-AgentLocalCiDependencySeeds {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Image,
        [Parameter(Mandatory = $true)][object]$Pipeline,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$Provenance,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$NamePrefix,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources,
        [Parameter(Mandatory = $true)][string]$LogDirectory
    )
    $needs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($stage in @($Profile.stages)) { foreach ($need in @($stage.needs)) { [void]$needs.Add([string]$need) } }
    if ($needs.Count -eq 0) { return [pscustomobject]@{ npm = $null; gradle = $null; proxy = $null } }
    $proxy = Start-AgentLocalCiDependencyProxy $Context $Image $Pipeline $RunId $NamePrefix $Resources $LogDirectory
    $npm = if ($needs.Contains("npm")) { New-AgentLocalCiNpmSeed $Context $Image $Pipeline $Provenance $proxy $RunId $NamePrefix $Resources $LogDirectory } else { $null }
    $gradle = if ($needs.Contains("gradle")) { New-AgentLocalCiGradleSeed $Context $Image $Pipeline $Provenance $proxy $RunId $NamePrefix $Resources $LogDirectory } else { $null }
    Invoke-AgentLocalCiDocker @("container", "stop", "--time", "5", $proxy.ProxyContainer) -AllowFailure | Out-Null
    return [pscustomobject]@{ npm = $npm; gradle = $gradle; proxy = $proxy }
}

function Invoke-AgentLocalCiDocker {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [switch]$AllowFailure
    )
    return Invoke-AgentLocalCiNative -FilePath (Get-AgentLocalCiDockerPath) -Arguments $Arguments -AllowFailure:$AllowFailure -Environment @{ DOCKER_CLI_HINTS = "false" }
}

function Get-AgentLocalCiDockerArchitecture {
    $value = (Invoke-AgentLocalCiDocker @("info", "--format", "{{.Architecture}}" )).Text.Trim().ToLowerInvariant()
    $architecture = switch ($value) {
        { $_ -in @("amd64", "x86_64") } { "amd64" }
        { $_ -in @("arm64", "aarch64") } { "arm64" }
        default { Throw-AgentLocalCi -Message "Docker architecture '$value' is unsupported; AgentLocalCI requires amd64 or arm64" -ExitCode 3 }
    }
    return $architecture
}

function ConvertFrom-AgentLocalCiSingleInspection {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Kind
    )
    try { $value = $Text | ConvertFrom-Json -Depth 100 }
    catch { Throw-AgentLocalCi -Message "Invalid Docker $Kind inspection JSON" -ExitCode 3 }
    $items = @($value)
    if ($items.Count -ne 1) { Throw-AgentLocalCi -Message "Expected exactly one Docker $Kind inspection object" -ExitCode 3 }
    return $items[0]
}

function Get-AgentLocalCiDockerPrefix {
    param([Parameter(Mandatory = $true)][string]$RunId)
    if (-not (Test-AgentLocalCiRunId $RunId)) { Throw-AgentLocalCi -Message "Invalid run identity" -ExitCode 4 }
    return "alc-" + $RunId.Substring($RunId.Length - 12)
}

function Get-AgentLocalCiResourceLabels {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Kind
    )
    return @(
        "--label", "io.agentlocalci.owner=$script:AgentLocalCiOwnerLabel",
        "--label", "io.agentlocalci.run=$RunId",
        "--label", "io.agentlocalci.kind=$Kind"
    )
}

function Initialize-AgentLocalCiTrustedBuildContext {
    param([Parameter(Mandatory = $true)][object]$Context)
    $identity = Get-AgentLocalCiControllerIdentity $Context
    $directory = Assert-AgentLocalCiOwnedPath (Join-Path $Context.BuildRoot $identity) $Context.BuildRoot
    if (Test-Path -LiteralPath $directory) {
        Assert-AgentLocalCiNoReparseAncestor $directory
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $mapping = [ordered]@{
        Dockerfile = $Context.Assets.Dockerfile
        "entrypoint.sh" = $Context.Assets.Entrypoint
        "runner.ps1" = $Context.Assets.Runner
        "proxy.mjs" = $Context.Assets.Proxy
        "proxy-health.mjs" = $Context.Assets.ProxyHealth
        "network-probe.mjs" = $Context.Assets.NetworkProbe
        "resolve-dependencies.gradle" = $Context.Assets.GradleResolver
    }
    foreach ($entry in $mapping.GetEnumerator()) {
        Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $directory $entry.Key) -Force
    }
    return [pscustomobject]@{ Identity = $identity; Directory = $directory; Tag = "agentlocalci:$identity" }
}

function Get-AgentLocalCiTrustedImage {
    param([Parameter(Mandatory = $true)][object]$Context)
    $build = Initialize-AgentLocalCiTrustedBuildContext $Context
    $expectedArchitecture = Get-AgentLocalCiDockerArchitecture
    $existing = Invoke-AgentLocalCiDocker @("image", "inspect", $build.Tag) -AllowFailure
    $mustBuild = $existing.ExitCode -ne 0
    if (-not $mustBuild) {
        try {
            $existingInspection = ConvertFrom-AgentLocalCiSingleInspection $existing.Text "image"
            $mustBuild = [string]$existingInspection.Architecture -cne $expectedArchitecture
        }
        catch { $mustBuild = $true }
    }
    if ($mustBuild) {
        $arguments = @("image", "build", "--pull=false", "--tag", $build.Tag, "--label", "io.agentlocalci.identity=$($build.Identity)", $build.Directory)
        Invoke-AgentLocalCiDocker $arguments | Out-Null
    }
    $inspection = ConvertFrom-AgentLocalCiSingleInspection (Invoke-AgentLocalCiDocker @("image", "inspect", $build.Tag)).Text "image"
    $failures = New-Object System.Collections.Generic.List[string]
    if ([string]$inspection.Id -cnotmatch '^sha256:[0-9a-f]{64}$') { $failures.Add("invalid immutable image ID") }
    if ([string]$inspection.Os -cne "linux") { $failures.Add("image OS is not linux") }
    if ([string]$inspection.Architecture -cne $expectedArchitecture) { $failures.Add("image architecture does not match the Docker server") }
    if ([string]$inspection.Config.User -cne $script:AgentLocalCiContainerUid) { $failures.Add("image user is not 10001:10001") }
    if ([string]$inspection.Config.Labels."io.agentlocalci.owner" -cne $script:AgentLocalCiOwnerLabel) { $failures.Add("owner label mismatch") }
    if ([string]$inspection.Config.Labels."io.agentlocalci.boundary" -cne $script:AgentLocalCiBoundaryMarker) { $failures.Add("boundary label mismatch") }
    if ([string]$inspection.Config.Labels."io.agentlocalci.identity" -cne $build.Identity) { $failures.Add("controller identity label mismatch") }
    if ([string]$inspection.Config.Labels."io.agentlocalci.arch" -cne $expectedArchitecture) { $failures.Add("architecture label mismatch") }
    if (@($inspection.Config.Entrypoint).Count -ne 1 -or [string]$inspection.Config.Entrypoint[0] -cne "/opt/agentlocalci/entrypoint.sh") { $failures.Add("entrypoint mismatch") }
    if ($failures.Count -gt 0) { Throw-AgentLocalCi -Message "Trusted image inspection failed: $($failures -join '; ')" -ExitCode 4 }
    return [pscustomobject]@{
        Id = [string]$inspection.Id
        Tag = $build.Tag
        Identity = $build.Identity
        BuiltAt = [string]$inspection.Created
        Architecture = [string]$inspection.Architecture
        Os = [string]$inspection.Os
    }
}

function New-AgentLocalCiDockerVolume {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources
    )
    if ($Name -cnotmatch '^[a-z0-9][a-z0-9_.-]{1,126}$') { Throw-AgentLocalCi -Message "Unsafe Docker volume name" -ExitCode 4 }
    if ((Invoke-AgentLocalCiDocker @("volume", "inspect", $Name) -AllowFailure).ExitCode -eq 0) { Throw-AgentLocalCi -Message "Refusing pre-existing Docker volume '$Name'" -ExitCode 4 }
    $Resources.Add([pscustomobject]@{ Type = "volume"; Name = $Name; Kind = $Kind; RunId = $RunId })
    Invoke-AgentLocalCiDocker (@("volume", "create") + (Get-AgentLocalCiResourceLabels $RunId $Kind) + @($Name)) | Out-Null
    $inspection = ConvertFrom-AgentLocalCiSingleInspection (Invoke-AgentLocalCiDocker @("volume", "inspect", $Name)).Text "volume"
    if ([string]$inspection.Driver -cne "local" -or ($null -ne $inspection.Options -and @($inspection.Options.PSObject.Properties).Count -gt 0)) { Throw-AgentLocalCi -Message "Volume '$Name' has unsafe driver settings" -ExitCode 4 }
    if ([string]$inspection.Labels."io.agentlocalci.owner" -cne $script:AgentLocalCiOwnerLabel -or [string]$inspection.Labels."io.agentlocalci.run" -cne $RunId -or [string]$inspection.Labels."io.agentlocalci.kind" -cne $Kind) { Throw-AgentLocalCi -Message "Volume '$Name' ownership labels failed" -ExitCode 4 }
    return $Name
}

function New-AgentLocalCiDockerNetwork {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources
    )
    if ($Name -cnotmatch '^[a-z0-9][a-z0-9_.-]{1,126}$') { Throw-AgentLocalCi -Message "Unsafe Docker network name" -ExitCode 4 }
    if ((Invoke-AgentLocalCiDocker @("network", "inspect", $Name) -AllowFailure).ExitCode -eq 0) { Throw-AgentLocalCi -Message "Refusing pre-existing Docker network '$Name'" -ExitCode 4 }
    $Resources.Add([pscustomobject]@{ Type = "network"; Name = $Name; Kind = "dependency-network"; RunId = $RunId })
    $arguments = @("network", "create", "--driver", "bridge", "--internal", "--ipv6=false", "--opt", "com.docker.network.bridge.gateway_mode_ipv4=isolated") + (Get-AgentLocalCiResourceLabels $RunId "dependency-network") + @($Name)
    Invoke-AgentLocalCiDocker $arguments | Out-Null
    $inspection = ConvertFrom-AgentLocalCiSingleInspection (Invoke-AgentLocalCiDocker @("network", "inspect", $Name)).Text "network"
    if ([string]$inspection.Driver -cne "bridge" -or -not [bool]$inspection.Internal -or [bool]$inspection.EnableIPv6 -or [string]$inspection.Options."com.docker.network.bridge.gateway_mode_ipv4" -cne "isolated") { Throw-AgentLocalCi -Message "Dependency network '$Name' is not an isolated internal bridge with IPv6 disabled" -ExitCode 4 }
    if ([string]$inspection.Labels."io.agentlocalci.owner" -cne $script:AgentLocalCiOwnerLabel -or [string]$inspection.Labels."io.agentlocalci.run" -cne $RunId -or [string]$inspection.Labels."io.agentlocalci.kind" -cne "dependency-network") { Throw-AgentLocalCi -Message "Network ownership labels failed" -ExitCode 4 }
    return $Name
}

function New-AgentLocalCiContainerBaseArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Network
    )
    $resources = $Context.Policy.resources
    return @(
        "container", "create", "--name", $Name,
        "--network", $Network,
        "--user", $script:AgentLocalCiContainerUid,
        "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
        "--cpus", ([string]$resources.cpu_limit),
        "--memory", ([string]$resources.memory_limit), "--memory-swap", ([string]$resources.memory_limit),
        "--pids-limit", ([string]$resources.pids_limit),
        "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=512m,uid=10001,gid=10001,mode=1777",
        "--tmpfs", "/home/ci:rw,nosuid,nodev,size=256m,uid=10001,gid=10001,mode=0700",
        "--env", "AGENTLOCALCI_EXECUTION_BOUNDARY=$script:AgentLocalCiBoundaryMarker",
        "--env", "AGENTLOCALCI_ARTIFACT_ROOT=/evidence",
        "--env", "HOME=/home/ci", "--env", "CI=true", "--env", "NEXT_TELEMETRY_DISABLED=1"
    ) + (Get-AgentLocalCiResourceLabels $RunId $Kind)
}

function New-AgentLocalCiTrackedContainer {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources
    )
    if ($Name -cnotmatch '^[a-z0-9][a-z0-9_.-]{1,126}$') { Throw-AgentLocalCi -Message "Unsafe Docker container name" -ExitCode 4 }
    if ((Invoke-AgentLocalCiDocker @("container", "inspect", $Name) -AllowFailure).ExitCode -eq 0) { Throw-AgentLocalCi -Message "Refusing pre-existing Docker container '$Name'" -ExitCode 4 }
    $Resources.Add([pscustomobject]@{ Type = "container"; Name = $Name; Kind = $Kind; RunId = $RunId })
    $created = Invoke-AgentLocalCiDocker $Arguments
    $id = ($created.Lines | Select-Object -Last 1).Trim()
    if ($id -cnotmatch '^[0-9a-f]{64}$') { Throw-AgentLocalCi -Message "Docker did not return a container identity" -ExitCode 3 }
    return $id
}

function Assert-AgentLocalCiRuntimeContainer {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExpectedImage,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExpectedVolumes,
        [Parameter(Mandatory = $true)][string]$ExpectedNetwork
    )
    $inspection = ConvertFrom-AgentLocalCiSingleInspection (Invoke-AgentLocalCiDocker @("container", "inspect", $Name)).Text "runtime container"
    $failures = New-Object System.Collections.Generic.List[string]
    if ([string]$inspection.Image -cne $ExpectedImage) { $failures.Add("image mismatch") }
    if ([string]$inspection.Config.User -cne $script:AgentLocalCiContainerUid) { $failures.Add("container is not UID 10001") }
    if ([bool]$inspection.HostConfig.Privileged) { $failures.Add("privileged=true") }
    if (-not [bool]$inspection.HostConfig.ReadonlyRootfs) { $failures.Add("root filesystem is writable") }
    if (@($inspection.HostConfig.CapDrop) -cnotcontains "ALL") { $failures.Add("all capabilities are not dropped") }
    if ($null -ne $inspection.HostConfig.CapAdd -and @($inspection.HostConfig.CapAdd).Count -gt 0) { $failures.Add("capabilities were added") }
    if (@($inspection.HostConfig.SecurityOpt) -notcontains "no-new-privileges:true") { $failures.Add("no-new-privileges missing") }
    if ($null -ne $inspection.HostConfig.Binds -and @($inspection.HostConfig.Binds).Count -gt 0) { $failures.Add("host bind mount present") }
    if ($null -ne $inspection.HostConfig.Devices -and @($inspection.HostConfig.Devices).Count -gt 0) { $failures.Add("device mapping present") }
    if ($null -ne $inspection.HostConfig.PortBindings -and @($inspection.HostConfig.PortBindings.PSObject.Properties).Count -gt 0) { $failures.Add("published port present") }
    if ([string]$inspection.HostConfig.NetworkMode -cne $ExpectedNetwork) { $failures.Add("network mode mismatch") }
    $actualVolumes = New-Object System.Collections.Generic.List[string]
    foreach ($mount in @($inspection.Mounts)) {
        if ([string]$mount.Type -cne "volume") { $failures.Add("non-volume mount present") }
        if ([string]$mount.Destination -match '(?i)docker\.sock|/run/host|/var/run') { $failures.Add("host control mount present") }
        $actualVolumes.Add([string]$mount.Name)
    }
    foreach ($volume in $ExpectedVolumes) { if ($actualVolumes -cnotcontains $volume) { $failures.Add("expected volume '$volume' missing") } }
    if ($actualVolumes.Count -ne $ExpectedVolumes.Count) { $failures.Add("unexpected volume count") }
    $environment = @($inspection.Config.Env | ForEach-Object { [string]$_ })
    foreach ($entry in $environment) {
        $environmentName = ($entry -split '=', 2)[0]
        if (Test-AgentLocalCiSensitiveEnvironmentName $environmentName) { $failures.Add("sensitive environment name '$environmentName' present") }
        if (Test-AgentLocalCiSecretLikeText $entry) { $failures.Add("secret-like environment value present") }
    }
    if ($failures.Count -gt 0) { Throw-AgentLocalCi -Message "Runtime boundary inspection failed for '$Name': $($failures -join '; ')" -ExitCode 4 }
}

function Start-AgentLocalCiContainerWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [ValidateRange(1, 1024)][int]$OutputLimitMiB = 50
    )
    if ($Name -cnotmatch '^[a-z0-9][a-z0-9_.-]{1,126}$') { Throw-AgentLocalCi -Message "Unsafe Docker container name" -ExitCode 4 }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-AgentLocalCiDockerPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @("container", "start", "--attach", $Name)) { [void]$startInfo.ArgumentList.Add($argument) }
    $startInfo.Environment["DOCKER_CLI_HINTS"] = "false"
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { Throw-AgentLocalCi -Message "Docker attach process did not start" -ExitCode 3 }
    try { $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
    $stdoutWriter = [IO.StreamWriter]::new($StdoutPath, $false, [Text.UTF8Encoding]::new($false))
    $stderrWriter = [IO.StreamWriter]::new($StderrPath, $false, [Text.UTF8Encoding]::new($false))
    $slots = @(
        [pscustomobject]@{ Reader = $process.StandardOutput; Writer = $stdoutWriter; Buffer = [char[]]::new(8192); Task = $null; Carry = ""; DiscardingLine = $false },
        [pscustomobject]@{ Reader = $process.StandardError; Writer = $stderrWriter; Buffer = [char[]]::new(8192); Task = $null; Carry = ""; DiscardingLine = $false }
    )
    foreach ($slot in $slots) { $slot.Task = $slot.Reader.ReadAsync($slot.Buffer, 0, $slot.Buffer.Length) }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $outputLimitExceeded = $false
    $observedCharacters = 0L
    $deadlineExpired = $false
    try {
        while ([DateTime]::UtcNow -lt $deadline -and -not $outputLimitExceeded) {
            $active = @($slots | Where-Object { $null -ne $_.Task })
            if ($active.Count -eq 0) {
                $probe = Invoke-AgentLocalCiDocker @("container", "inspect", $Name, "--format", "{{.State.Running}}") -AllowFailure
                if ($probe.ExitCode -ne 0 -or $probe.Text.Trim() -cne "true") { break }
                Start-Sleep -Milliseconds 250
                continue
            }
            $tasks = [Threading.Tasks.Task[]]@($active | ForEach-Object { $_.Task })
            $index = [Threading.Tasks.Task]::WaitAny($tasks, 500)
            if ($index -lt 0) { continue }
            $slot = $active[$index]
            $count = [int]$slot.Task.Result
            if ($count -eq 0) { $slot.Task = $null; continue }
            $observedCharacters += $count
            if ($observedCharacters -gt ($OutputLimitMiB * 1MB)) { $outputLimitExceeded = $true; break }
            Write-AgentLocalCiRedactedStreamChunk -Slot $slot -Chunk ([string]::new($slot.Buffer, 0, $count))
            $slot.Task = $slot.Reader.ReadAsync($slot.Buffer, 0, $slot.Buffer.Length)
        }
        $running = Invoke-AgentLocalCiDocker @("container", "inspect", $Name, "--format", "{{.State.Running}}") -AllowFailure
        $deadlineExpired = -not $outputLimitExceeded -and [DateTime]::UtcNow -ge $deadline -and $running.ExitCode -eq 0 -and $running.Text.Trim() -ceq "true"
        if ($deadlineExpired -or $outputLimitExceeded) { Invoke-AgentLocalCiDocker @("container", "kill", "--signal", "KILL", $Name) -AllowFailure | Out-Null }
    }
    finally {
        foreach ($slot in $slots) { Write-AgentLocalCiRedactedStreamChunk -Slot $slot -EndOfStream; $slot.Writer.Flush(); $slot.Writer.Dispose(); $slot.Reader.Dispose() }
    }
    if ($deadlineExpired -or $outputLimitExceeded) {
        if (-not $process.WaitForExit(30000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    else { $process.WaitForExit() }
    $state = (Invoke-AgentLocalCiDocker @("container", "inspect", $Name, "--format", "{{json .State}}")).Text | ConvertFrom-Json
    $process.Dispose()
    if ($outputLimitExceeded) { Add-Content -LiteralPath $stderrPath -Value "AgentLocalCI terminated the container after exceeding the sanitized output bound." -Encoding UTF8 }
    return [pscustomobject]@{ TimedOut = $deadlineExpired; OutputLimitExceeded = $outputLimitExceeded; ExitCode = if ($deadlineExpired) { 124 } elseif ($outputLimitExceeded) { 125 } else { [int]$state.ExitCode }; DockerState = $state }
}

function Get-AgentLocalCiDockerResourcePresence {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("container", "network", "volume")][string]$Type,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Name -cnotmatch '^[a-z0-9][a-z0-9_.-]{1,126}$') {
        return [pscustomobject]@{ State = "InspectionError"; Detail = "unsafe Docker resource name" }
    }
    $arguments = switch ($Type) {
        "container" { @("container", "ls", "--all", "--format", "{{.Names}}") }
        "network" { @("network", "ls", "--format", "{{.Name}}") }
        "volume" { @("volume", "ls", "--format", "{{.Name}}") }
    }
    $listing = Invoke-AgentLocalCiDocker $arguments -AllowFailure
    if ($listing.ExitCode -ne 0) {
        return [pscustomobject]@{ State = "InspectionError"; Detail = "Docker $Type enumeration failed" }
    }
    $matches = @($listing.Lines | Where-Object { $_.Trim() -ceq $Name })
    if ($matches.Count -eq 0) { return [pscustomobject]@{ State = "Absent"; Detail = $null } }
    if ($matches.Count -ne 1) {
        return [pscustomobject]@{ State = "InspectionError"; Detail = "Docker returned an ambiguous exact-name match" }
    }
    $inspection = Invoke-AgentLocalCiDocker @($Type, "inspect", $Name) -AllowFailure
    if ($inspection.ExitCode -ne 0) {
        return [pscustomobject]@{ State = "InspectionError"; Detail = "Docker could not inspect the enumerated resource" }
    }
    return [pscustomobject]@{ State = "Present"; Detail = $null }
}

function Test-AgentLocalCiResourceOwnership {
    param([Parameter(Mandatory = $true)][object]$Resource)
    if (
        [string]$Resource.Type -notin @("container", "network", "volume") -or
        [string]$Resource.Name -cnotmatch '^[a-z0-9][a-z0-9_.-]{1,126}$' -or
        -not (Test-AgentLocalCiRunId ([string]$Resource.RunId)) -or
        [string]$Resource.Kind -cnotmatch '^[a-z0-9][a-z0-9_.-]{0,126}$'
    ) { return $false }
    $result = switch ([string]$Resource.Type) {
        "container" { Invoke-AgentLocalCiDocker @("container", "inspect", [string]$Resource.Name) -AllowFailure }
        "network" { Invoke-AgentLocalCiDocker @("network", "inspect", [string]$Resource.Name) -AllowFailure }
        "volume" { Invoke-AgentLocalCiDocker @("volume", "inspect", [string]$Resource.Name) -AllowFailure }
    }
    if ($result.ExitCode -ne 0) { return $false }
    try { $inspection = ConvertFrom-AgentLocalCiSingleInspection $result.Text ([string]$Resource.Type) }
    catch { return $false }
    $labels = if ([string]$Resource.Type -ceq "container") { $inspection.Config.Labels } else { $inspection.Labels }
    return (
        [string]$labels."io.agentlocalci.owner" -ceq $script:AgentLocalCiOwnerLabel -and
        [string]$labels."io.agentlocalci.run" -ceq [string]$Resource.RunId -and
        [string]$labels."io.agentlocalci.kind" -ceq [string]$Resource.Kind
    )
}

function Remove-AgentLocalCiResources {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Resources)
    $failures = New-Object System.Collections.Generic.List[string]
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($type in @("container", "network", "volume")) {
        $typedResources = @($Resources.ToArray() | Where-Object { [string]$_.Type -ceq $type })
        for ($index = $typedResources.Count - 1; $index -ge 0; $index--) {
            $resource = $typedResources[$index]
            $key = "$type|$([string]$resource.Name)"
            if (-not $seen.Add($key)) { continue }
            try {
                $presence = Get-AgentLocalCiDockerResourcePresence $type ([string]$resource.Name)
                if ($presence.State -ceq "Absent") { continue }
                if ($presence.State -cne "Present") {
                    $failures.Add("${key}: $($presence.Detail); absence is unverified")
                    continue
                }
                if (-not (Test-AgentLocalCiResourceOwnership $resource)) {
                    $failures.Add("${key}: ownership labels do not exactly match the recorded run and kind")
                    continue
                }
                $arguments = switch ($type) {
                    "container" { @("container", "rm", "--force", [string]$resource.Name) }
                    "network" { @("network", "rm", [string]$resource.Name) }
                    "volume" { @("volume", "rm", [string]$resource.Name) }
                }
                $result = Invoke-AgentLocalCiDocker $arguments -AllowFailure
                if ($result.ExitCode -ne 0) {
                    $failures.Add("${key}: Docker removal failed")
                    continue
                }
                $after = Get-AgentLocalCiDockerResourcePresence $type ([string]$resource.Name)
                if ($after.State -cne "Absent") {
                    $failures.Add("${key}: absence was not proven after cleanup: $($after.Detail)")
                }
            }
            catch {
                $failures.Add("${key}: " + (ConvertTo-AgentLocalCiRedactedText $_.Exception.Message))
            }
        }
    }
    return [pscustomobject]@{ Passed = ($failures.Count -eq 0); Failures = $failures.ToArray() }
}

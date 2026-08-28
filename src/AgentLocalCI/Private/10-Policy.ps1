function New-AgentLocalCiDefaultPolicy {
    $logical = [Math]::Max(1, [Environment]::ProcessorCount)
    $cpu = if ($logical -le 2) { 1 } else { [Math]::Min(6, $logical - 2) }
    $memoryGiB = Get-AgentLocalCiRecommendedMemoryGiB
    return [pscustomobject]@{
        schema_version = 1
        enabled = $true
        executor = "docker"
        max_parallel = 1
        allow_host_executor = $false
        allow_privileged = $false
        allow_host_network = $false
        allow_host_mounts = $false
        allow_docker_socket = $false
        allow_devices = $false
        allow_custom_images = $false
        allow_secrets = $false
        allowed_environment_names = @("NODE_ENV", "TZ", "LANG", "LC_ALL")
        allowed_dependency_hosts = @(
            "dl.google.com", "downloads.gradle.org", "github.com",
            "github-releases.githubusercontent.com", "maven.google.com",
            "objects.githubusercontent.com", "plugins-artifacts.gradle.org",
            "plugins.gradle.org", "registry.npmjs.org",
            "release-assets.githubusercontent.com", "repo.maven.apache.org",
            "services.gradle.org", "storage.googleapis.com"
        )
        resources = [pscustomobject]@{
            cpu_limit = $cpu
            memory_limit = "${memoryGiB}g"
            pids_limit = 768
            stage_timeout_seconds = 1800
            run_timeout_seconds = 14400
            output_limit_mib = 50
            minimum_free_disk_gib = 20
            gradle_max_workers = 2
        }
        required_profiles = @()
        required_stage_ids = [pscustomobject]@{}
    }
}

function Test-AgentLocalCiEnvironmentName {
    param([AllowNull()][string]$Name)
    return -not [string]::IsNullOrWhiteSpace($Name) -and $Name -cmatch '^[A-Z][A-Z0-9_]{0,63}$'
}

function Test-AgentLocalCiSensitiveEnvironmentName {
    param([AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -match '(?i)(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_?KEY|API_?KEY|ACCESS_?KEY|SIGNING_?KEY|SESSION_?KEY)') { return $true }
    return $Name -match '(?i)(^|_)(AUTH|AUTHORIZATION|COOKIE|KEY|CERT|CERTIFICATE|SESSION|PAT|SSH|AWS|AZURE|GOOGLE|GITHUB|GITLAB|STRIPE|PAYMENT|KYC)($|_)'
}

function Test-AgentLocalCiDependencyHost {
    param([AllowNull()][string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName) -or $HostName.Length -gt 253) { return $false }
    if ($HostName.Contains("*") -or $HostName.Contains(":") -or $HostName.Contains("/") -or $HostName.EndsWith(".")) { return $false }
    if ($HostName -match '^\d{1,3}(?:\.\d{1,3}){3}$' -or $HostName -cnotmatch '^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$') { return $false }
    foreach ($label in @($HostName -split '\.')) {
        if ($label.Length -lt 1 -or $label.Length -gt 63 -or $label.StartsWith("-") -or $label.EndsWith("-")) { return $false }
    }
    return $HostName.Contains(".")
}

function ConvertTo-AgentLocalCiStringArray {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$AllowEmpty
    )
    if ($null -eq $Value) {
        if ($AllowEmpty) { return @() }
        Throw-AgentLocalCi -Message "$Context must be an array" -ExitCode 2
    }
    if ($Value -is [string]) { Throw-AgentLocalCi -Message "$Context must be an array, not a string" -ExitCode 2 }
    $items = @($Value)
    if (-not $AllowEmpty -and $items.Count -eq 0) { Throw-AgentLocalCi -Message "$Context must not be empty" -ExitCode 2 }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) { Throw-AgentLocalCi -Message "$Context contains an empty or non-string value" -ExitCode 2 }
        $result.Add([string]$item)
    }
    return $result.ToArray()
}

function Assert-AgentLocalCiPolicy {
    param([Parameter(Mandatory = $true)][object]$Policy)
    Assert-AgentLocalCiKnownProperties -Value $Policy -Allowed @(
        "schema_version", "enabled", "executor", "max_parallel",
        "allow_host_executor", "allow_privileged", "allow_host_network", "allow_host_mounts",
        "allow_docker_socket", "allow_devices", "allow_custom_images", "allow_secrets",
        "allowed_environment_names", "allowed_dependency_hosts", "resources",
        "required_profiles", "required_stage_ids"
    ) -Context "machine policy"
    if ([int](Get-AgentLocalCiRequiredProperty -Value $Policy -Name "schema_version" -Context "machine policy") -ne 1) { Throw-AgentLocalCi -Message "Unsupported machine policy schema" -ExitCode 2 }
    foreach ($name in @("enabled", "allow_host_executor", "allow_privileged", "allow_host_network", "allow_host_mounts", "allow_docker_socket", "allow_devices", "allow_custom_images", "allow_secrets")) {
        if ((Get-AgentLocalCiRequiredProperty -Value $Policy -Name $name -Context "machine policy") -isnot [bool]) { Throw-AgentLocalCi -Message "machine policy '$name' must be boolean" -ExitCode 2 }
    }
    if ([string]$Policy.executor -cne "docker" -or [int]$Policy.max_parallel -ne 1) { Throw-AgentLocalCi -Message "AgentLocalCI 0.2 requires docker and max_parallel=1" -ExitCode 2 }
    if ($Policy.allow_host_executor -or $Policy.allow_privileged -or $Policy.allow_host_network -or $Policy.allow_host_mounts -or $Policy.allow_docker_socket -or $Policy.allow_devices -or $Policy.allow_custom_images -or $Policy.allow_secrets) {
        Throw-AgentLocalCi -Message "AgentLocalCI 0.2 fails closed when any unsafe capability is enabled" -ExitCode 4
    }
    $environmentSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @(ConvertTo-AgentLocalCiStringArray -Value $Policy.allowed_environment_names -Context "allowed_environment_names" -AllowEmpty)) {
        if (-not (Test-AgentLocalCiEnvironmentName $name) -or (Test-AgentLocalCiSensitiveEnvironmentName $name) -or -not $environmentSet.Add($name)) { Throw-AgentLocalCi -Message "Unsafe or duplicate allowed environment name: $name" -ExitCode 2 }
    }
    $hostSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hostName in @(ConvertTo-AgentLocalCiStringArray -Value $Policy.allowed_dependency_hosts -Context "allowed_dependency_hosts" -AllowEmpty)) {
        if (-not (Test-AgentLocalCiDependencyHost $hostName) -or -not $hostSet.Add($hostName)) { Throw-AgentLocalCi -Message "Unsafe or duplicate dependency host: $hostName" -ExitCode 2 }
    }
    $resources = Get-AgentLocalCiRequiredProperty -Value $Policy -Name "resources" -Context "machine policy"
    Assert-AgentLocalCiKnownProperties -Value $resources -Allowed @("cpu_limit", "memory_limit", "pids_limit", "stage_timeout_seconds", "run_timeout_seconds", "output_limit_mib", "minimum_free_disk_gib", "gradle_max_workers") -Context "machine policy resources"
    $limits = @(
        @("cpu_limit", [double]$resources.cpu_limit, 0.5, 64),
        @("pids_limit", [double]$resources.pids_limit, 64, 8192),
        @("stage_timeout_seconds", [double]$resources.stage_timeout_seconds, 30, 86400),
        @("run_timeout_seconds", [double]$resources.run_timeout_seconds, 60, 172800),
        @("output_limit_mib", [double]$resources.output_limit_mib, 1, 1024),
        @("minimum_free_disk_gib", [double]$resources.minimum_free_disk_gib, 1, 1024),
        @("gradle_max_workers", [double]$resources.gradle_max_workers, 1, 16)
    )
    foreach ($limit in $limits) { if ($limit[1] -lt $limit[2] -or $limit[1] -gt $limit[3]) { Throw-AgentLocalCi -Message "resources.$($limit[0]) is outside $($limit[2])..$($limit[3])" -ExitCode 2 } }
    if ([string]$resources.memory_limit -cnotmatch '^[1-9][0-9]{0,3}(m|g)$') { Throw-AgentLocalCi -Message "resources.memory_limit must look like 512m or 8g" -ExitCode 2 }
    foreach ($profileName in @(ConvertTo-AgentLocalCiStringArray -Value $Policy.required_profiles -Context "required_profiles" -AllowEmpty)) {
        if ($profileName -cnotmatch '^[a-z][a-z0-9-]{0,63}$') { Throw-AgentLocalCi -Message "Invalid required profile: $profileName" -ExitCode 2 }
    }
    $requiredStages = Get-AgentLocalCiRequiredProperty -Value $Policy -Name "required_stage_ids" -Context "machine policy"
    foreach ($property in $requiredStages.PSObject.Properties) {
        if ($property.Name -cnotmatch '^[a-z][a-z0-9-]{0,63}$') { Throw-AgentLocalCi -Message "Invalid required-stage profile: $($property.Name)" -ExitCode 2 }
        foreach ($stageId in @(ConvertTo-AgentLocalCiStringArray -Value $property.Value -Context "required_stage_ids.$($property.Name)" -AllowEmpty)) {
            if ($stageId -cnotmatch '^[a-z][a-z0-9-]{0,63}$') { Throw-AgentLocalCi -Message "Invalid required stage: $stageId" -ExitCode 2 }
        }
    }
    return $Policy
}

function Read-AgentLocalCiPolicy {
    param([Parameter(Mandatory = $true)][string]$PolicyPath)
    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) { return Assert-AgentLocalCiPolicy (New-AgentLocalCiDefaultPolicy) }
    Assert-AgentLocalCiNoReparseAncestor -Path $PolicyPath
    return Assert-AgentLocalCiPolicy (ConvertFrom-AgentLocalCiJsonYaml -Text (Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8) -SourceName $PolicyPath)
}

function ConvertTo-AgentLocalCiEnvironmentMap {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][object]$Policy,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $result = [ordered]@{}
    if ($null -eq $Value) { return [pscustomobject]$result }
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @($Policy.allowed_environment_names)) { [void]$allowed.Add([string]$name) }
    foreach ($property in $Value.PSObject.Properties) {
        $name = [string]$property.Name
        if (-not (Test-AgentLocalCiEnvironmentName $name) -or (Test-AgentLocalCiSensitiveEnvironmentName $name) -or -not $allowed.Contains($name)) { Throw-AgentLocalCi -Message "$Context environment '$name' is denied" -ExitCode 4 }
        if ($property.Value -isnot [string]) { Throw-AgentLocalCi -Message "$Context environment '$name' must be a string" -ExitCode 2 }
        $text = [string]$property.Value
        if ($text.Length -gt 4096 -or $text.IndexOf([char]0) -ge 0 -or (Test-AgentLocalCiSecretLikeText $text)) { Throw-AgentLocalCi -Message "$Context environment '$name' is unsafe or secret-like" -ExitCode 4 }
        $result[$name] = $text
    }
    return [pscustomobject]$result
}

function Get-AgentLocalCiHostPlatform {
    if ($IsWindows) { return "windows" }
    if ($IsMacOS) { return "macos" }
    if ($IsLinux) { return "linux" }
    return "unsupported"
}

function Get-AgentLocalCiPathComparison {
    if ((Get-AgentLocalCiHostPlatform) -ceq "windows") {
        return [StringComparison]::OrdinalIgnoreCase
    }
    return [StringComparison]::Ordinal
}

function Get-AgentLocalCiPathComparer {
    if ((Get-AgentLocalCiHostPlatform) -ceq "windows") {
        return [StringComparer]::OrdinalIgnoreCase
    }
    return [StringComparer]::Ordinal
}

function Test-AgentLocalCiPathEquals {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    return $Left.Equals($Right, (Get-AgentLocalCiPathComparison))
}

function Get-AgentLocalCiNullDevice {
    if ((Get-AgentLocalCiHostPlatform) -ceq "windows") { return "NUL" }
    return "/dev/null"
}

function Get-AgentLocalCiUserHome {
    $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($homePath)) { $homePath = [Environment]::GetEnvironmentVariable("HOME", "Process") }
    if ([string]::IsNullOrWhiteSpace($homePath)) { Throw-AgentLocalCi -Message "The current user home directory is unavailable" -ExitCode 3 }
    return [IO.Path]::GetFullPath($homePath)
}

function Get-AgentLocalCiDefaultHome {
    switch (Get-AgentLocalCiHostPlatform) {
        "windows" {
            $root = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            if ([string]::IsNullOrWhiteSpace($root)) { Throw-AgentLocalCi -Message "LOCALAPPDATA is unavailable" -ExitCode 3 }
            return (Join-Path $root "AgentLocalCI")
        }
        "macos" {
            return (Join-Path (Get-AgentLocalCiUserHome) "Library/Application Support/AgentLocalCI")
        }
        "linux" {
            $stateRoot = [Environment]::GetEnvironmentVariable("XDG_STATE_HOME", "Process")
            if ([string]::IsNullOrWhiteSpace($stateRoot)) {
                $stateRoot = Join-Path (Get-AgentLocalCiUserHome) ".local/state"
            }
            return (Join-Path $stateRoot "agentlocalci")
        }
        default { Throw-AgentLocalCi -Message "AgentLocalCI does not support this host platform" -ExitCode 3 }
    }
}

function Get-AgentLocalCiPhysicalMemoryBytes {
    try {
        switch (Get-AgentLocalCiHostPlatform) {
            "windows" {
                return [int64](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
            }
            "macos" {
                $sysctl = Get-AgentLocalCiApplicationPath -Names @("/usr/sbin/sysctl", "sysctl") -Purpose "macOS sysctl"
                $value = (Invoke-AgentLocalCiNative -FilePath $sysctl -Arguments @("-n", "hw.memsize")).Text.Trim()
                $bytes = 0L
                if ([int64]::TryParse($value, [ref]$bytes) -and $bytes -gt 0) { return $bytes }
            }
            "linux" {
                if (Test-Path -LiteralPath "/proc/meminfo" -PathType Leaf) {
                    $line = Get-Content -LiteralPath "/proc/meminfo" -Encoding UTF8 | Where-Object { $_ -match '^MemTotal:\s+(\d+)\s+kB$' } | Select-Object -First 1
                    if ($line -match '^MemTotal:\s+(\d+)\s+kB$') { return [int64]$Matches[1] * 1KB }
                }
            }
        }
    }
    catch { }
    return 8GB
}

function Get-AgentLocalCiRecommendedMemoryGiB {
    $physicalBytes = Get-AgentLocalCiPhysicalMemoryBytes
    return [Math]::Max(4, [Math]::Min(16, [Math]::Floor(([double]$physicalBytes / 1GB) * 0.60)))
}

function Get-AgentLocalCiFreeDiskBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    if ([string]::IsNullOrWhiteSpace($root)) { Throw-AgentLocalCi -Message "Cannot determine the filesystem root for free-space inspection" -ExitCode 3 }
    return [int64]([IO.DriveInfo]::new($root).AvailableFreeSpace)
}

function Open-AgentLocalCiPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Get-AgentLocalCiSafeFullPath $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Throw-AgentLocalCi -Message "Report file does not exist: $full" -ExitCode 2 }
    switch (Get-AgentLocalCiHostPlatform) {
        "windows" { Start-Process -FilePath $full | Out-Null }
        "macos" { [void](Invoke-AgentLocalCiNative -FilePath "/usr/bin/open" -Arguments @($full)) }
        "linux" {
            $opener = Get-AgentLocalCiApplicationPath -Names @("xdg-open") -Purpose "xdg-open"
            [void](Invoke-AgentLocalCiNative -FilePath $opener -Arguments @($full))
        }
        default { Throw-AgentLocalCi -Message "Opening a report is unsupported on this host" -ExitCode 3 }
    }
    return $full
}

function Get-AgentLocalCiHostArchitecture {
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $normalized = switch ($architecture) {
        "x64" { "amd64" }
        "arm64" { "arm64" }
        "x86" { "386" }
        "arm" { "arm" }
        default { $architecture }
    }
    return $normalized
}

function Get-AgentLocalCiPlatformSupport {
    $platform = Get-AgentLocalCiHostPlatform
    return [pscustomobject]@{
        Platform = $platform
        Supported = $platform -in @("windows", "macos", "linux")
        Status = switch ($platform) {
            "windows" { "supported" }
            "macos" { "beta" }
            "linux" { "beta" }
            default { "unsupported" }
        }
    }
}

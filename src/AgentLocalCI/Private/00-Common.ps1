function New-AgentLocalCiException {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet(1, 2, 3, 4, 5, 6, 130)][int]$ExitCode = 1
    )

    $exception = [InvalidOperationException]::new($Message)
    $exception.Data["AgentLocalCiExitCode"] = $ExitCode
    return $exception
}

function Throw-AgentLocalCi {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet(1, 2, 3, 4, 5, 6, 130)][int]$ExitCode = 1
    )

    throw (New-AgentLocalCiException -Message $Message -ExitCode $ExitCode)
}

function Get-AgentLocalCiExceptionExitCode {
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    if ($Exception.Data.Contains("AgentLocalCiExitCode")) {
        $value = [int]$Exception.Data["AgentLocalCiExitCode"]
        if ($value -in @(1, 2, 3, 4, 5, 6, 130)) { return $value }
    }
    return 1
}

function Get-AgentLocalCiStringSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return (($algorithm.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $algorithm.Dispose()
    }
}

function ConvertTo-AgentLocalCiRedactedText {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return $null }
    $safe = [Regex]::Replace($Text, "`e\[[0-?]*[ -/]*[@-~]", "")
    $safe = [Regex]::Replace($safe, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    $safe = [Regex]::Replace($safe, '(?i)\b[A-Z]:[\\/](?:Users|Documents and Settings)[\\/][^\\/\r\n]+(?:[\\/][^\r\n;|]*)?', '<redacted-user-path>')
    $safe = [Regex]::Replace($safe, '(?i)(?<![A-Za-z0-9])[A-Z]:[\\/][^\s"''<>|;]+', '<redacted-absolute-path>')
    $safe = [Regex]::Replace($safe, '(?i)(?<![\\])\\\\[^\\\s]+\\[^\\\s]+(?:\\[^\s"''<>|;]+)*', '<redacted-unc-path>')
    $safe = [Regex]::Replace($safe, '(?i)(?<![A-Za-z0-9])/(?:home|Users)/[^/\s]+(?:/[^\s"'';|]+)*', '<redacted-user-path>')
    $safe = [Regex]::Replace($safe, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '<redacted-email>')
    $safe = [Regex]::Replace($safe, '\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}|127(?:\.\d{1,3}){3}|169\.254(?:\.\d{1,3}){2})\b', '<redacted-private-ip>')
    $safe = [Regex]::Replace(
        $safe,
        '(?i)(\b(?:password|passwd|token|secret|private[_-]?key|service[_-]?role[_-]?key|publishable[_-]?key|api[_-]?key|authorization|cookie)\b\s*[=:]\s*)(?:"[^"]*"|''[^'']*''|[^\s,;]+)',
        '$1<redacted>'
    )
    $safe = [Regex]::Replace(
        $safe,
        '(?i)\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|(?:AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|(?:sk|rk)_live_[0-9A-Za-z]{20,})\b',
        '<redacted-token>'
    )
    $safe = [Regex]::Replace(
        $safe,
        '(?i)\b(?:Bearer\s+)[A-Za-z0-9._~+/=-]{16,}',
        'Bearer <redacted>'
    )
    $safe = [Regex]::Replace(
        $safe,
        '\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b',
        '<redacted-jwt>'
    )
    $safe = [Regex]::Replace(
        $safe,
        '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
        '<redacted-private-key-marker>'
    )
    $safe = [Regex]::Replace(
        $safe,
        '(?<![A-Za-z0-9])[A-Za-z0-9_+/=-]{64,}(?![A-Za-z0-9])',
        '<redacted-long-token>'
    )
    return $safe
}

function Test-AgentLocalCiSecretLikeText {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return $Text -match '(?i)(?:-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|(?:AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|(?:sk|rk)_live_[0-9A-Za-z]{20,}|\bBearer\s+[A-Za-z0-9._~+/=-]{16,}|\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b)'
}

function Write-AgentLocalCiRedactedStreamChunk {
    param(
        [Parameter(Mandatory = $true)][object]$Slot,
        [AllowEmptyString()][string]$Chunk = "",
        [ValidateRange(64, 1048576)][int]$MaximumLineCharacters = 16384,
        [switch]$EndOfStream
    )

    $text = $Slot.Carry + $Chunk
    $Slot.Carry = ""
    $position = 0
    while ($position -lt $text.Length) {
        $newline = $text.IndexOf("`n", $position, [StringComparison]::Ordinal)
        if ($newline -lt 0) {
            $remaining = $text.Substring($position)
            if ($Slot.DiscardingLine) {
                if ($EndOfStream) { $Slot.DiscardingLine = $false }
                return
            }
            if ($remaining.Length -gt $MaximumLineCharacters) {
                $Slot.Writer.WriteLine("[AgentLocalCI discarded an overlong untrusted output line]")
                $Slot.DiscardingLine = $true
                if ($EndOfStream) { $Slot.DiscardingLine = $false }
                return
            }
            if ($EndOfStream) {
                if ($remaining.Length -gt 0) {
                    $Slot.Writer.WriteLine((ConvertTo-AgentLocalCiRedactedText -Text $remaining.TrimEnd("`r")))
                }
            }
            else {
                $Slot.Carry = $remaining
            }
            return
        }

        $line = $text.Substring($position, $newline - $position).TrimEnd("`r")
        $position = $newline + 1
        if ($Slot.DiscardingLine) {
            $Slot.DiscardingLine = $false
            continue
        }
        if ($line.Length -gt $MaximumLineCharacters) {
            $Slot.Writer.WriteLine("[AgentLocalCI discarded an overlong untrusted output line]")
            continue
        }
        $Slot.Writer.WriteLine((ConvertTo-AgentLocalCiRedactedText -Text $line))
    }

    if ($EndOfStream -and $Slot.DiscardingLine) {
        $Slot.DiscardingLine = $false
    }
}

function Get-AgentLocalCiSafeFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('"') -or $Path.IndexOf([char]0) -ge 0) {
        Throw-AgentLocalCi -Message "Unsafe filesystem path" -ExitCode 4
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if (Test-AgentLocalCiPathEquals $full $root) { return $root }
    return $full.TrimEnd([char[]]@('\', '/'))
}

function Test-AgentLocalCiPathContained {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $child = Get-AgentLocalCiSafeFullPath -Path $Path
    $root = Get-AgentLocalCiSafeFullPath -Path $Parent
    $separator = [IO.Path]::DirectorySeparatorChar
    $prefix = if ($root.EndsWith([string]$separator, [StringComparison]::Ordinal)) { $root } else { "$root$separator" }
    $comparison = Get-AgentLocalCiPathComparison
    return $child.Equals($root, $comparison) -or $child.StartsWith($prefix, $comparison)
}

function Assert-AgentLocalCiNoReparseAncestor {
    param([Parameter(Mandatory = $true)][string]$Path)

    $cursor = Get-AgentLocalCiSafeFullPath -Path $Path
    $root = [IO.Path]::GetPathRoot($cursor)
    while ($true) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-AgentLocalCi -Message "AgentLocalCI refuses a reparse point or junction ancestor: $cursor" -ExitCode 4
            }
        }
        if (Test-AgentLocalCiPathEquals $cursor $root) { break }
        $parentInfo = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parentInfo) {
            Throw-AgentLocalCi -Message "Could not reach the filesystem root while validating path ancestors" -ExitCode 4
        }
        $parentFull = [IO.Path]::GetFullPath($parentInfo.FullName)
        $cursor = if (Test-AgentLocalCiPathEquals $parentFull $root) {
            $root
        }
        else {
            $parentFull.TrimEnd([char[]]@('\', '/'))
        }
    }
}

function Assert-AgentLocalCiPathIsNarrow {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Get-AgentLocalCiSafeFullPath -Path $Path
    $root = [IO.Path]::GetPathRoot($full)
    if (Test-AgentLocalCiPathEquals $full $root) {
        Throw-AgentLocalCi -Message "AgentLocalCI refuses a filesystem root as a mutation boundary" -ExitCode 4
    }
    $relative = $full.Substring($root.Length).Trim([char[]]@('\', '/'))
    $segments = @($relative -split '[\\/]' | Where-Object { $_ })
    if ($segments.Count -lt 2) {
        Throw-AgentLocalCi -Message "AgentLocalCI refuses a broad mutation boundary: $full" -ExitCode 4
    }
    Assert-AgentLocalCiNoReparseAncestor -Path $full
    return $full
}

function Assert-AgentLocalCiOwnedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Boundary
    )

    $full = Get-AgentLocalCiSafeFullPath -Path $Path
    $root = Get-AgentLocalCiSafeFullPath -Path $Boundary
    if (-not (Test-AgentLocalCiPathContained -Path $full -Parent $root)) {
        Throw-AgentLocalCi -Message "Path escaped its AgentLocalCI-owned boundary" -ExitCode 4
    }
    Assert-AgentLocalCiNoReparseAncestor -Path $full
    return $full
}

function New-AgentLocalCiOwnedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Boundary
    )

    $full = Assert-AgentLocalCiOwnedPath -Path $Path -Boundary $Boundary
    if (-not (Test-Path -LiteralPath $full)) {
        [IO.Directory]::CreateDirectory($full) | Out-Null
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Throw-AgentLocalCi -Message "Expected a directory: $full" -ExitCode 4
    }
    Assert-AgentLocalCiNoReparseAncestor -Path $full
    return $full
}

function Write-AgentLocalCiJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    Assert-AgentLocalCiNoReparseAncestor -Path $parent
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($Value | ConvertTo-Json -Depth 100),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Read-AgentLocalCiJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100)
    }
    catch {
        Throw-AgentLocalCi -Message "Invalid JSON document: $Path" -ExitCode 2
    }
}

function ConvertFrom-AgentLocalCiJsonYaml {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    $trimmed = $Text.TrimStart()
    if (-not $trimmed.StartsWith("{", [StringComparison]::Ordinal)) {
        Throw-AgentLocalCi -Message "$SourceName must use JSON-compatible YAML in AgentLocalCI 0.2. JSON is valid YAML 1.2; arbitrary YAML syntax is not yet accepted." -ExitCode 2
    }
    try {
        return ($Text | ConvertFrom-Json -Depth 100)
    }
    catch {
        Throw-AgentLocalCi -Message "Invalid JSON-compatible YAML in ${SourceName}: $($_.Exception.Message)" -ExitCode 2
    }
}

function Get-AgentLocalCiObjectPropertyNames {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return @() }
    return @($Value.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-AgentLocalCiKnownProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Context
    )

    foreach ($name in @(Get-AgentLocalCiObjectPropertyNames -Value $Value)) {
        if ($Allowed -cnotcontains $name) {
            Throw-AgentLocalCi -Message "$Context contains unsupported property '$name'" -ExitCode 2
        }
    }
}

function Get-AgentLocalCiRequiredProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) {
        Throw-AgentLocalCi -Message "$Context is missing required property '$Name'" -ExitCode 2
    }
    return $property.Value
}

function Get-AgentLocalCiArrayProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$AllowMissing,
        [switch]$AllowEmpty
    )

    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) {
        if ($AllowMissing) { return }
        Throw-AgentLocalCi -Message "$Context is missing required array property '$Name'" -ExitCode 2
    }
    if ($null -eq $property.Value -or $property.Value -isnot [Array]) {
        Throw-AgentLocalCi -Message "$Context property '$Name' must be an array" -ExitCode 2
    }
    $items = @($property.Value)
    if (-not $AllowEmpty -and $items.Count -eq 0) {
        Throw-AgentLocalCi -Message "$Context property '$Name' must not be empty" -ExitCode 2
    }
    foreach ($item in $items) {
        Write-Output $item
    }
}

function Test-AgentLocalCiSafeRelativePath {
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -ceq ".") { return $true }
    if (
        [IO.Path]::IsPathRooted($Path) -or
        $Path.Contains('"') -or $Path.Contains("'") -or $Path.Contains(':') -or
        $Path -match '[\x00-\x1F\x7F]'
    ) { return $false }
    $normalized = $Path.Replace('\', '/')
    if ($normalized.StartsWith("/", [StringComparison]::Ordinal) -or $normalized.EndsWith("/", [StringComparison]::Ordinal)) { return $false }
    foreach ($segment in @($normalized -split '/')) {
        if ($segment -in @("", ".", "..")) { return $false }
    }
    return $true
}

function Resolve-AgentLocalCiRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if (-not (Test-AgentLocalCiSafeRelativePath -Path $RelativePath)) {
        Throw-AgentLocalCi -Message "Unsafe relative path '$RelativePath'" -ExitCode 2
    }
    $resolved = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (-not (Test-AgentLocalCiPathContained -Path $resolved -Parent $Root)) {
        Throw-AgentLocalCi -Message "Relative path escaped its root: $RelativePath" -ExitCode 4
    }
    return $resolved
}

function New-AgentLocalCiRunId {
    $timestamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmssfff")
    $random = [Guid]::NewGuid().ToString("N").Substring(0, 12)
    return "$timestamp-$random"
}

function Test-AgentLocalCiRunId {
    param([AllowNull()][string]$RunId)
    return -not [string]::IsNullOrWhiteSpace($RunId) -and $RunId -cmatch '^\d{8}-\d{9}-[0-9a-f]{12}$'
}

function Invoke-AgentLocalCiNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [switch]$AllowFailure,
        [AllowNull()][string]$StandardInputText,
        [hashtable]$Environment,
        [string[]]$RemoveEnvironmentPrefixes = @()
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $StandardInputText
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    foreach ($prefix in $RemoveEnvironmentPrefixes) {
        foreach ($key in @($startInfo.Environment.Keys)) {
            if ($key.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$startInfo.Environment.Remove($key)
            }
        }
    }
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            $startInfo.Environment[[string]$key] = [string]$Environment[$key]
        }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            Throw-AgentLocalCi -Message "Failed to start native controller command" -ExitCode 3
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StandardInputText) {
            $process.StandardInput.Write($StandardInputText)
            $process.StandardInput.Close()
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = [int]$process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($stdout)) {
        foreach ($line in @($stdout.TrimEnd("`r", "`n") -split '\r?\n')) { $lines.Add([string]$line) }
    }
    if (-not [string]::IsNullOrEmpty($stderr)) {
        foreach ($line in @($stderr.TrimEnd("`r", "`n") -split '\r?\n')) { $lines.Add([string]$line) }
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $safeTail = ConvertTo-AgentLocalCiRedactedText -Text (($lines | Select-Object -Last 12) -join "`n")
        Throw-AgentLocalCi -Message "Command '$([IO.Path]::GetFileName($FilePath))' failed with exit code $exitCode. $safeTail" -ExitCode 1
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines = $lines.ToArray()
        Text = ($lines -join "`n")
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Get-AgentLocalCiApplicationPath {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    foreach ($name in $Names) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    Throw-AgentLocalCi -Message "$Purpose is required but was not found on PATH" -ExitCode 3
}

function Get-AgentLocalCiGitPath {
    return Get-AgentLocalCiApplicationPath -Names @("git.exe", "git") -Purpose "Git"
}

function Get-AgentLocalCiDockerPath {
    return Get-AgentLocalCiApplicationPath -Names @("docker.exe", "docker") -Purpose "Docker Desktop CLI"
}

function Get-AgentLocalCiPwshPath {
    return Get-AgentLocalCiApplicationPath -Names @("pwsh.exe", "pwsh") -Purpose "PowerShell 7"
}

function New-AgentLocalCiControllerLock {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$RunId,
        [ValidateRange(0, 86400)][int]$WaitSeconds
    )

    $lockPath = Join-Path $Context.LocksRoot "controller.lock"
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    while ($true) {
        try {
            $stream = [IO.FileStream]::new(
                $lockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::Read
            )
            $owner = [ordered]@{
                schema_version = 1
                run_id = $RunId
                process_id = $PID
                process_started_utc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")
                acquired_utc = [DateTime]::UtcNow.ToString("o")
                machine = [Environment]::MachineName
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($owner | ConvertTo-Json -Compress))
            $stream.SetLength(0)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            return $stream
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                Throw-AgentLocalCi -Message "AgentLocalCI is busy and the serialized queue wait expired after $WaitSeconds seconds" -ExitCode 4
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Test-AgentLocalCiProcessIdentityAlive {
    param(
        [int]$ProcessId,
        [AllowNull()][string]$ProcessStartedUtc
    )

    if ($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($ProcessStartedUtc)) { return $false }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return $process.StartTime.ToUniversalTime().ToString("o") -ceq ([DateTime]$ProcessStartedUtc).ToUniversalTime().ToString("o")
    }
    catch {
        return $false
    }
}

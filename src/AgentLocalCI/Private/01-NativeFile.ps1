function Invoke-AgentLocalCiNativeToFile {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$StandardOutputPath,
        [switch]$AllowFailure,
        [AllowNull()][string]$StandardInputText,
        [hashtable]$Environment,
        [string[]]$RemoveEnvironmentPrefixes = @()
    )

    $outputPath = [IO.Path]::GetFullPath($StandardOutputPath)
    $outputParent = [IO.Path]::GetDirectoryName($outputPath)
    if ([string]::IsNullOrWhiteSpace($outputParent) -or
        -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        Throw-AgentLocalCi -Message "Native controller output directory does not exist" -ExitCode 3
    }
    if (Test-Path -LiteralPath $outputPath) {
        Throw-AgentLocalCi -Message "Native controller output file already exists" -ExitCode 3
    }
    $temporaryPath = Join-Path $outputParent (
        ".agentlocalci-native-" + [Guid]::NewGuid().ToString("N") + ".tmp"
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
    $outputStream = $null
    $stderr = ""
    $exitCode = -1
    $bytesWritten = 0L
    try {
        $outputStream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        if (-not $process.Start()) {
            Throw-AgentLocalCi -Message "Failed to start native controller command" -ExitCode 3
        }
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($outputStream)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StandardInputText) {
            $process.StandardInput.Write($StandardInputText)
            $process.StandardInput.Close()
        }
        $process.WaitForExit()
        [void]$copyTask.GetAwaiter().GetResult()
        $outputStream.Flush($true)
        $bytesWritten = $outputStream.Length
        $outputStream.Dispose()
        $outputStream = $null
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = [int]$process.ExitCode
    }
    finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        $process.Dispose()
    }

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($stderr)) {
        foreach ($line in @($stderr.TrimEnd("`r", "`n") -split '\r?\n')) {
            $lines.Add([string]$line)
        }
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        $safeTail = ConvertTo-AgentLocalCiRedactedText -Text (
            ($lines | Select-Object -Last 12) -join "`n"
        )
        Throw-AgentLocalCi -Message "Command '$([IO.Path]::GetFileName($FilePath))' failed with exit code $exitCode. $safeTail" -ExitCode 1
    }
    if ($exitCode -eq 0 -and $bytesWritten -le 0) {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        Throw-AgentLocalCi -Message "Native controller command produced an empty output file" -ExitCode 3
    }
    try {
        [IO.File]::Move($temporaryPath, $outputPath)
    }
    catch {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        Throw-AgentLocalCi -Message "Failed to finalize native controller output file" -ExitCode 3
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines = $lines.ToArray()
        Text = ($lines -join "`n")
        Stdout = ""
        Stderr = $stderr
        OutputPath = $outputPath
        BytesWritten = $bytesWritten
    }
}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ImageReference,
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\artifacts\agentlocalci-image.spdx.json")
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $resolvedOutput
[IO.Directory]::CreateDirectory($parent) | Out-Null
$temporaryOutput = "$resolvedOutput.$([Guid]::NewGuid().ToString('N')).tmp"

$process = [Diagnostics.Process]::new()
$process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
$process.StartInfo.FileName = "docker.exe"
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $true
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
foreach ($argument in @(
    "sbom", $ImageReference,
    "--format", "spdx-json",
    "--quiet",
    "--output", $temporaryOutput
)) {
    [void]$process.StartInfo.ArgumentList.Add($argument)
}

try {
    if (-not $process.Start()) { throw "docker sbom did not start" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($process.ExitCode -ne 0) {
        $detail = (($stderr, $stdout) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "; "
        throw "docker sbom failed with exit $($process.ExitCode): $detail"
    }
    if (-not (Test-Path -LiteralPath $temporaryOutput -PathType Leaf)) {
        throw "docker sbom did not create the requested output"
    }

    $document = [IO.File]::ReadAllText($temporaryOutput, [Text.Encoding]::UTF8)
    [void]($document | ConvertFrom-Json -Depth 100)
    Move-Item -LiteralPath $temporaryOutput -Destination $resolvedOutput -Force

    [pscustomobject]@{
        Image = $ImageReference
        Output = $resolvedOutput
        Bytes = (Get-Item -LiteralPath $resolvedOutput).Length
        Sha256 = (Get-FileHash -LiteralPath $resolvedOutput -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
finally {
    if (-not $process.HasExited) {
        try { $process.Kill($true) } catch { }
    }
    $process.Dispose()
    if (Test-Path -LiteralPath $temporaryOutput -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryOutput -Force
    }
}

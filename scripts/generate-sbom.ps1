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
$process = [Diagnostics.Process]::new()
$process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
$process.StartInfo.FileName = 'docker.exe'
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
foreach ($argument in @('sbom', $ImageReference, '--format', 'spdx-json')) { [void]$process.StartInfo.ArgumentList.Add($argument) }
try {
    if (-not $process.Start()) { throw 'docker sbom did not start' }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "docker sbom failed with exit $($process.ExitCode): $stderr" }
    [void]($stdout | ConvertFrom-Json -Depth 100)
    [IO.File]::WriteAllText($resolvedOutput, $stdout, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Image = $ImageReference; Output = $resolvedOutput; Sha256 = (Get-FileHash -LiteralPath $resolvedOutput -Algorithm SHA256).Hash.ToLowerInvariant() }
}
finally { $process.Dispose() }

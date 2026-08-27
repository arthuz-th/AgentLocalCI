$module = Join-Path $PSScriptRoot "..\src\AgentLocalCI\AgentLocalCI.psm1"
if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {
    [Console]::Error.WriteLine("AgentLocalCI module is missing: $module")
    exit 3
}

Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
Import-Module $module -Force -ErrorAction Stop
$invocation = @(Invoke-AgentLocalCiCli -Arguments $args)
if ($invocation.Count -eq 0 -or $invocation[-1] -isnot [int]) {
    [Console]::Error.WriteLine("AgentLocalCI returned an invalid command result")
    exit 1
}
$exitCode = [int]$invocation[-1]
if ($invocation.Count -gt 1) {
    $invocation[0..($invocation.Count - 2)] | Write-Output
}
exit $exitCode

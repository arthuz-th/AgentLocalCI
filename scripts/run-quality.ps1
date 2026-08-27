[CmdletBinding()]
param([string]$Root = (Join-Path $PSScriptRoot ".."))

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath($Root)
$failures = [Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) { $script:failures.Add($Message) }
function Get-Relative([string]$Path) { return [IO.Path]::GetRelativePath($repoRoot, $Path).Replace([char]92, '/') }
function Is-Ignored([string]$Path) { return $Path -match '[/\\](?:\.git|\.test-tmp|test-results|node_modules|\.gradle)(?:[/\\]|$)' }

$required = @(
    "README.md", "LICENSE", "NOTICE", "SECURITY.md", "THREAT_MODEL.md", "CONTRIBUTING.md",
    "CODE_OF_CONDUCT.md", "GOVERNANCE.md", "SUPPORT.md", "CHANGELOG.md",
    "schemas/pipeline.schema.json", "schemas/policy.schema.json", "schemas/report.schema.json",
    ".agentlocalci/pipeline.yml"
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $relative) -PathType Leaf)) { Add-Failure "missing required file: $relative" }
}
if (Test-Path -LiteralPath (Join-Path $repoRoot ".github/workflows")) { Add-Failure ".github/workflows is intentionally unsupported in this local-only repository" }

$syntaxFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Include *.ps1,*.psm1 | Where-Object { -not (Is-Ignored $_.FullName) })
foreach ($file in $syntaxFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in @($parseErrors)) { Add-Failure "PowerShell syntax: $(Get-Relative $file.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)" }
}

$jsonFiles = [Collections.Generic.Dictionary[string, IO.FileInfo]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter *.json | Where-Object { -not (Is-Ignored $_.FullName) })) { $jsonFiles[$file.FullName] = $file }
foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter pipeline.yml | Where-Object { -not (Is-Ignored $_.FullName) })) { $jsonFiles[$file.FullName] = $file }
$jsonFiles[(Join-Path $repoRoot "config/default-policy.yml")] = Get-Item -LiteralPath (Join-Path $repoRoot "config/default-policy.yml")
foreach ($file in $jsonFiles.Values) {
    try { [void](Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100) }
    catch { Add-Failure "JSON-compatible document is invalid: $(Get-Relative $file.FullName)" }
}

$secretScript = Join-Path $repoRoot "scripts/secret-scan.ps1"
if (Test-Path -LiteralPath $secretScript -PathType Leaf) {
    & pwsh -NoLogo -NoProfile -NonInteractive -File $secretScript -Root $repoRoot
    if ($LASTEXITCODE -ne 0) { Add-Failure "public-source safety scan failed" }
}
else { Add-Failure "missing scripts/secret-scan.ps1" }

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { [Console]::Error.WriteLine($failure) }
    Write-Output "RESULT passed=false failures=$($failures.Count)"
    exit 1
}
Write-Output "RESULT passed=true powershell_files=$($syntaxFiles.Count) json_documents=$($jsonFiles.Count)"
exit 0

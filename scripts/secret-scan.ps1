[CmdletBinding()]
param(
    [string]$Root = (Join-Path $PSScriptRoot ".."),
    [switch]$IncludeHistory
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath($Root)
$findings = [Collections.Generic.List[string]]::new()
$maximumBytes = 2MB
$textExtensions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($extension in @('.ps1','.psm1','.cmd','.sh','.mjs','.js','.ts','.tsx','.json','.yml','.yaml','.md','.txt','.gradle','.properties','.toml','.xml','.html','.css','.gitignore','.gitattributes','.editorconfig')) { [void]$textExtensions.Add($extension) }
$tokenFixturePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($path in @('src/AgentLocalCI/Private/00-Common.ps1','scripts/secret-scan.ps1')) { [void]$tokenFixturePaths.Add($path) }

$patterns = @(
    [pscustomobject]@{ Name = 'private-key'; Regex = '(?i)-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----' },
    [pscustomobject]@{ Name = 'github-token'; Regex = '(?i)\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,})\b' },
    [pscustomobject]@{ Name = 'slack-token'; Regex = '(?i)\bxox[baprs]-[A-Za-z0-9-]{20,}\b' },
    [pscustomobject]@{ Name = 'aws-access-key'; Regex = '\b(?:AKIA|ASIA)[0-9A-Z]{16}\b' },
    [pscustomobject]@{ Name = 'google-api-key'; Regex = '\bAIza[0-9A-Za-z_-]{35}\b' },
    [pscustomobject]@{ Name = 'live-payment-key'; Regex = '(?i)\b(?:sk|rk)_live_[0-9A-Za-z]{20,}\b' },
    [pscustomobject]@{ Name = 'bearer-token'; Regex = '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}' },
    [pscustomobject]@{ Name = 'jwt'; Regex = '\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b' },
    [pscustomobject]@{ Name = 'credential-url'; Regex = '(?i)https?://[^\s/:@]+:[^\s/@]+@' },
    [pscustomobject]@{ Name = 'assigned-secret'; Regex = '(?i)\b(?:password|passwd|client_secret|api_key|access_token)\s*[:=]\s*["''][^"'']{12,}["'']' }
)
$pathPatterns = @(
    [pscustomobject]@{ Name = 'absolute-user-path'; Regex = '(?i)\b[A-Z]:[\\/](?:Users|Documents and Settings)[\\/][^\\/\s]+' },
    [pscustomobject]@{ Name = 'application-workspace-path'; Regex = '(?i)\b[A-Z]:[\\/]APP[\\/][^\s"'']+' },
    [pscustomobject]@{ Name = 'wsl-unc-path'; Regex = '(?i)\\\\wsl(?:\.localhost)?\\[^\\\s]+' }
)

function Add-Finding([string]$Location, [string]$Kind) {
    $entry = "$Location [$Kind]"
    if (-not $findings.Contains($entry)) { $findings.Add($entry) }
}
function Get-Relative([string]$Path) { return [IO.Path]::GetRelativePath($repoRoot, $Path).Replace([char]92, '/') }
function Is-Ignored([string]$Path) { return $Path -match '[/\\](?:\.git|\.test-tmp|test-results|node_modules|\.gradle)(?:[/\\]|$)' }

$forbiddenNames = '(?i)(^|[.])(env|npmrc|pypirc)$|(^|[._-])id_(rsa|dsa|ecdsa|ed25519)$|\.(pem|key|p12|pfx|jks|keystore)$'
foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force | Where-Object { -not (Is-Ignored $_.FullName) })) {
    $relative = Get-Relative $file.FullName
    if ($relative -match $forbiddenNames -and $relative -cne '.env.example') { Add-Finding $relative 'secret-like-filename' }
    $extension = [IO.Path]::GetExtension($file.Name)
    if (-not $textExtensions.Contains($extension) -or $file.Length -gt $maximumBytes) { continue }
    try { $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) }
    catch { Add-Finding $relative 'unreadable-text'; continue }
    foreach ($pattern in $pathPatterns) { if ($text -match $pattern.Regex) { Add-Finding $relative $pattern.Name } }
    if (-not $tokenFixturePaths.Contains($relative)) {
        foreach ($pattern in $patterns) { if ($text -match $pattern.Regex) { Add-Finding $relative $pattern.Name } }
    }
}

if ($IncludeHistory) {
    $gitDirectory = Join-Path $repoRoot '.git'
    if (Test-Path -LiteralPath $gitDirectory) {
        $history = (& git -C $repoRoot --no-pager log --all -p --full-history --no-ext-diff --no-textconv -- . ':(exclude)src/AgentLocalCI/Private/00-Common.ps1' ':(exclude)scripts/secret-scan.ps1' 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0) { Add-Finding 'git-history' 'scan-failed' }
        else {
            foreach ($pattern in @($patterns + $pathPatterns)) { if ($history -match $pattern.Regex) { Add-Finding 'git-history' $pattern.Name } }
        }
    }
}

if ($findings.Count -gt 0) {
    foreach ($finding in $findings) { [Console]::Error.WriteLine("FINDING $finding") }
    Write-Output "RESULT passed=false findings=$($findings.Count)"
    exit 1
}
Write-Output "RESULT passed=true findings=0"
exit 0

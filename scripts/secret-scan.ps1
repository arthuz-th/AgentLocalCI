[CmdletBinding()]
param(
    [string]$Root = (Join-Path $PSScriptRoot ".."),
    [switch]$IncludeHistory
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath($Root)
$findings = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$maximumBytes = 2MB

function Get-Relative([string]$Path) {
    return [IO.Path]::GetRelativePath($repoRoot, $Path).Replace([char]92, '/')
}

function Test-IgnoredPath([string]$Path) {
    return $Path -match '[/\\](?:\.git|\.test-tmp|test-results|node_modules|\.gradle|artifacts)(?:[/\\]|$)'
}

function Add-Finding([string]$Location, [string]$Kind) {
    [void]$findings.Add("$Location [$Kind]")
}

$textExtensions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($extension in @(
    '.ps1', '.psm1', '.psd1', '.cmd', '.sh', '.mjs', '.js', '.ts', '.tsx',
    '.json', '.yml', '.yaml', '.md', '.txt', '.gradle', '.properties', '.toml',
    '.xml', '.html', '.css', '.gitignore', '.gitattributes', '.editorconfig'
)) {
    [void]$textExtensions.Add($extension)
}

$tokenDefinitionPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($path in @(
    'src/AgentLocalCI/Private/00-Common.ps1',
    'scripts/secret-scan.ps1'
)) {
    [void]$tokenDefinitionPaths.Add($path)
}

$tokenPatterns = @(
    [pscustomobject]@{ Name = 'github-token'; Regex = '(?i)\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,})\b' },
    [pscustomobject]@{ Name = 'slack-token'; Regex = '(?i)\bxox[baprs]-[A-Za-z0-9-]{20,}\b' },
    [pscustomobject]@{ Name = 'google-api-key'; Regex = '\bAIza[0-9A-Za-z_-]{35}\b' },
    [pscustomobject]@{ Name = 'aws-access-key'; Regex = '\b(?:AKIA|ASIA)[0-9A-Z]{16}\b' },
    [pscustomobject]@{ Name = 'live-payment-key'; Regex = '(?i)\b(?:sk|rk)_live_[0-9A-Za-z]{20,}\b' },
    [pscustomobject]@{ Name = 'bearer-token'; Regex = '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}' },
    [pscustomobject]@{ Name = 'jwt'; Regex = '\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b' },
    [pscustomobject]@{ Name = 'private-key'; Regex = '(?i)-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----' }
)

$pathPatterns = @(
    [pscustomobject]@{ Name = 'absolute-user-path'; Regex = '(?i)\b[A-Z]:[\\/](?:Users|Documents and Settings)[\\/][^\\/\s"''<>|;]+' },
    [pscustomobject]@{ Name = 'application-workspace-path'; Regex = '(?i)\b[A-Z]:[\\/]APP[\\/][^\s"''<>|;]+' },
    [pscustomobject]@{ Name = 'wsl-unc-path'; Regex = '(?i)\\\\wsl(?:\.localhost)?\\[^\\\s]+' },
    [pscustomobject]@{ Name = 'credential-url'; Regex = '(?i)https?://[^\s/:@]+:[^\s/@]+@' },
    [pscustomobject]@{ Name = 'assigned-secret'; Regex = '(?i)\b(?:password|passwd|client_secret|api_key|access_token)\s*[:=]\s*["''][^"'']{12,}["'']' }
)

$forbiddenNamePattern = '(?i)(^|[.])(env|npmrc|pypirc)$|(^|[._-])id_(rsa|dsa|ecdsa|ed25519)$|\.(pem|key|p12|pfx|jks|keystore)$'

foreach ($file in @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force | Where-Object { -not (Test-IgnoredPath $_.FullName) })) {
    $relative = Get-Relative $file.FullName
    if ($relative -match $forbiddenNamePattern -and $relative -cne '.env.example') {
        Add-Finding $relative 'secret-like-filename'
    }

    $extension = [IO.Path]::GetExtension($file.Name)
    if (-not $textExtensions.Contains($extension) -or $file.Length -gt $maximumBytes) { continue }

    try {
        $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    }
    catch {
        Add-Finding $relative 'unreadable-text'
        continue
    }

    foreach ($pattern in $pathPatterns) {
        if ($text -match $pattern.Regex) { Add-Finding $relative $pattern.Name }
    }
    if (-not $tokenDefinitionPaths.Contains($relative)) {
        foreach ($pattern in $tokenPatterns) {
            if ($text -match $pattern.Regex) { Add-Finding $relative $pattern.Name }
        }
    }
}

if ($IncludeHistory) {
    $gitDirectory = Join-Path $repoRoot '.git'
    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) {
        Add-Finding 'git-history' 'repository-missing'
    }
    else {
        $historyArguments = @(
            '-C', $repoRoot, '--no-pager', 'log', '--all', '-p', '--full-history',
            '--no-ext-diff', '--no-textconv', '--', '.',
            ':(exclude)src/AgentLocalCI/Private/00-Common.ps1',
            ':(exclude)scripts/secret-scan.ps1'
        )
        $history = (& git.exe @historyArguments 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0) {
            Add-Finding 'git-history' 'scan-failed'
        }
        else {
            foreach ($pattern in @($tokenPatterns + $pathPatterns)) {
                if ($history -match $pattern.Regex) { Add-Finding 'git-history' $pattern.Name }
            }
        }
    }
}

if ($findings.Count -gt 0) {
    foreach ($finding in @($findings | Sort-Object)) {
        [Console]::Error.WriteLine("FINDING $finding")
    }
    Write-Output "RESULT passed=false findings=$($findings.Count)"
    exit 1
}

Write-Output "RESULT passed=true findings=0 history=$([bool]$IncludeHistory)"
exit 0

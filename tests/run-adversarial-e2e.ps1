[CmdletBinding()]
param([switch]$KeepArtifacts)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$cliPath = Join-Path $repoRoot "bin\agentlocalci.ps1"
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-symlink-fixture-" + [Guid]::NewGuid().ToString("N"))
$temporaryHome = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-symlink-home-" + [Guid]::NewGuid().ToString("N"))

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = @(& git.exe -C $fixtureRoot @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join '; ')" }
    return $output
}

try {
    & git.exe init -q -b main $fixtureRoot
    if ($LASTEXITCODE -ne 0) { throw "fixture git init failed" }
    Invoke-Git @("config", "user.name", "AgentLocalCI Test") | Out-Null
    Invoke-Git @("config", "user.email", "test@example.invalid") | Out-Null

    $pipelineDirectory = Join-Path $fixtureRoot ".agentlocalci"
    [IO.Directory]::CreateDirectory($pipelineDirectory) | Out-Null
    $pipeline = @'
{
  "schema_version": 1,
  "project": { "name": "agentlocalci-symlink-adversarial" },
  "default_profile": "standard",
  "dependency_hosts": [],
  "environment": {},
  "dependencies": {},
  "profiles": {
    "standard": {
      "description": "A committed symlink must not move the stage working directory outside the exact tree",
      "acceptance": true,
      "gaps": [],
      "stages": [
        {
          "id": "symlink-escape",
          "command": ["/usr/bin/true"],
          "working_directory": "escape",
          "needs": [],
          "timeout_seconds": 300
        }
      ]
    }
  }
}
'@
    [IO.File]::WriteAllText((Join-Path $pipelineDirectory "pipeline.yml"), $pipeline, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot "README.md"), "adversarial fixture`n", [Text.UTF8Encoding]::new($false))
    Invoke-Git @("add", ".agentlocalci/pipeline.yml", "README.md") | Out-Null

    $targetPath = Join-Path $fixtureRoot ".symlink-target"
    [IO.File]::WriteAllText($targetPath, "/tmp", [Text.UTF8Encoding]::new($false))
    $blob = (Invoke-Git @("hash-object", "-w", ".symlink-target") | Select-Object -Last 1).Trim()
    if ($blob -cnotmatch '^[0-9a-f]{40}$') { throw "fixture symlink blob identity is invalid" }
    Invoke-Git @("update-index", "--add", "--cacheinfo", "120000", $blob, "escape") | Out-Null
    Remove-Item -LiteralPath $targetPath -Force
    Invoke-Git @("commit", "-q", "-m", "symlink escape fixture") | Out-Null
    $sha = (Invoke-Git @("rev-parse", "HEAD") | Select-Object -Last 1).Trim()
    $treeEntry = (Invoke-Git @("ls-tree", $sha, "--", "escape") | Select-Object -Last 1).Trim()
    if ($treeEntry -cnotmatch '^120000 blob [0-9a-f]{40}\tescape$') { throw "fixture did not contain an exact Git symbolic-link entry: $treeEntry" }

    $output = @(& pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cliPath run --sha $sha --profile standard --home $temporaryHome --repository $fixtureRoot 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 4) { throw "symlink escape returned $exitCode instead of safety exit 4: $($output -join '; ')" }

    $reportFile = Get-ChildItem -LiteralPath (Join-Path $temporaryHome "runtime\runs") -Filter report.json -File -Recurse | Sort-Object FullName -Descending | Select-Object -First 1
    if ($null -eq $reportFile) { throw "symlink escape run did not create a report" }
    $report = Get-Content -LiteralPath $reportFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    if ([string]$report.result -cne "SafetyBlocked" -or [int]$report.exit_code -ne 4) { throw "symlink escape was not classified as SafetyBlocked" }
    if ([string]$report.cleanup.status -cne "Passed") { throw "symlink escape cleanup did not pass" }
    if (@($report.stages).Count -ne 1 -or [string]$report.stages[0].status -cne "SafetyBlocked" -or [int]$report.stages[0].exit_code -ne 200) {
        throw "symlink escape stage did not preserve the trusted-runner safety classification"
    }
    Write-Output "PASS exact-tree symbolic-link working-directory escape was blocked and cleaned"
}
finally {
    if ($KeepArtifacts) {
        Write-Output "PRESERVED fixture=$fixtureRoot"
        Write-Output "PRESERVED home=$temporaryHome"
    }
    else {
        if ((Test-Path -LiteralPath $temporaryHome) -and (Test-Path -LiteralPath $fixtureRoot)) {
            & pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cliPath clean --wait-seconds 1 --home $temporaryHome --repository $fixtureRoot *> $null
        }
        foreach ($path in @($fixtureRoot, $temporaryHome)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    }
}

[CmdletBinding()]
param([switch]$KeepArtifacts)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$cliPath = Join-Path $repoRoot "bin/agentlocalci.ps1"
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-beginner-fixture-" + [Guid]::NewGuid().ToString("N"))
$temporaryHome = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-beginner-home-" + [Guid]::NewGuid().ToString("N"))
$gitCommand = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$pwshCommand = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = @(& $gitCommand -C $fixtureRoot @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join '; ')" }
    return $output
}

try {
    & $gitCommand init -q -b main $fixtureRoot
    if ($LASTEXITCODE -ne 0) { throw "fixture git init failed" }
    Invoke-Git @("config", "user.name", "AgentLocalCI Beginner Test") | Out-Null
    Invoke-Git @("config", "user.email", "test@example.invalid") | Out-Null

    $packageJson = @'
{
  "name": "agentlocalci-beginner-e2e",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node test.mjs"
  },
  "dependencies": {
    "is-number": "7.0.0"
  }
}
'@
    $packageLock = @'
{
  "name": "agentlocalci-beginner-e2e",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "agentlocalci-beginner-e2e",
      "version": "1.0.0",
      "dependencies": {
        "is-number": "7.0.0"
      }
    },
    "node_modules/is-number": {
      "version": "7.0.0",
      "resolved": "https://registry.npmjs.org/is-number/-/is-number-7.0.0.tgz",
      "integrity": "sha512-41Cifkg6e8TylSpdtTpeLVMqvSBEVzTttHvERD741+pnZ8ANv0004MRL43QKPDlK9cGvNp6NZWZUBlbGXYxxng==",
      "license": "MIT",
      "engines": { "node": ">=0.12.0" }
    }
  }
}
'@
    $testScript = @'
import isNumber from "is-number";
import net from "node:net";

if (!isNumber("42") || isNumber("not-a-number")) {
  throw new Error("prepared npm dependency is unavailable or incorrect");
}
if (process.env.AGENTLOCALCI_EXECUTION_BOUNDARY !== "unprivileged-linux-container") {
  throw new Error("execution boundary marker is missing");
}
if (!/^[0-9a-f]{40}$/.test(process.env.AGENTLOCALCI_TARGET_SHA || "")) {
  throw new Error("exact target SHA marker is missing");
}
const directNetworkSucceeded = await new Promise((resolve) => {
  const socket = net.connect({ host: "1.1.1.1", port: 443 });
  const finish = (value) => { socket.destroy(); resolve(value); };
  socket.setTimeout(1500, () => finish(false));
  socket.once("connect", () => finish(true));
  socket.once("error", () => finish(false));
});
if (directNetworkSucceeded) throw new Error("validation unexpectedly reached a public IP");
console.log("beginner quickstart npm dependency and offline boundary passed");
'@
    [IO.File]::WriteAllText((Join-Path $fixtureRoot "package.json"), $packageJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot "package-lock.json"), $packageLock, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot "test.mjs"), $testScript, [Text.UTF8Encoding]::new($false))
    Invoke-Git @("add", "package.json", "package-lock.json", "test.mjs") | Out-Null
    Invoke-Git @("commit", "-q", "-m", "beginner fixture") | Out-Null
    $baseSha = (Invoke-Git @("rev-parse", "HEAD") | Select-Object -Last 1).Trim()

    $output = @(& $pwshCommand -NoLogo -NoProfile -NonInteractive -File $cliPath quickstart --commit --home $temporaryHome --repository $fixtureRoot 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "quickstart returned $exitCode`: $($output -join '; ')" }

    $head = (Invoke-Git @("rev-parse", "HEAD") | Select-Object -Last 1).Trim()
    if ($head -ceq $baseSha) { throw "quickstart did not create the narrow configuration commit" }
    $changed = @(Invoke-Git @("diff-tree", "--no-commit-id", "--name-only", "-r", $head) | Where-Object { $_ })
    if ($changed.Count -ne 1 -or [string]$changed[0] -cne ".agentlocalci/pipeline.yml") { throw "quickstart commit changed unexpected paths: $($changed -join ', ')" }
    if (@(Invoke-Git @("status", "--porcelain=v1", "--untracked-files=all") | Where-Object { $_ }).Count -ne 0) { throw "quickstart left a dirty fixture" }

    $pipeline = Get-Content -LiteralPath (Join-Path $fixtureRoot ".agentlocalci/pipeline.yml") -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50
    if ([string]$pipeline.default_profile -cne "standard" -or @($pipeline.profiles.standard.stages).Count -ne 1 -or [string]$pipeline.profiles.standard.stages[0].id -cne "test") { throw "quickstart did not detect the useful npm test script" }
    if (($pipeline.profiles.standard.stages[0].command -join " ") -cne "npm test") { throw "quickstart embedded an unexpected npm command" }

    $reportFile = Get-ChildItem -LiteralPath (Join-Path $temporaryHome "runtime/runs") -Filter report.json -File -Recurse | Sort-Object FullName -Descending | Select-Object -First 1
    if ($null -eq $reportFile) { throw "quickstart did not create a report" }
    $report = Get-Content -LiteralPath $reportFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    if ([string]$report.result -cne "Passed" -or [int]$report.exit_code -ne 0 -or [string]$report.target_sha -cne $head) { throw "quickstart report did not pass the exact generated commit" }
    if ([string]$report.security.validation_network -cne "none" -or [string]$report.cleanup.status -cne "Passed" -or [bool]$report.security.credentials_forwarded) { throw "quickstart report lost the safety boundary" }
    if (@($report.stages).Count -ne 1 -or [string]$report.stages[0].status -cne "Passed") { throw "quickstart stage did not pass" }
    $html = Join-Path $reportFile.DirectoryName "report.html"
    if (-not (Test-Path -LiteralPath $html -PathType Leaf) -or (Get-Item -LiteralPath $html).Length -lt 1000) { throw "quickstart HTML report is missing or empty" }

    Write-Output "PASS one-command beginner quickstart detected npm, created only its config commit, fetched through the controlled phase, validated offline, reported exact source, and cleaned up"
}
finally {
    if ($KeepArtifacts) {
        Write-Output "PRESERVED fixture=$fixtureRoot"
        Write-Output "PRESERVED home=$temporaryHome"
    }
    else {
        if ((Test-Path -LiteralPath $temporaryHome) -and (Test-Path -LiteralPath $fixtureRoot)) {
            & $pwshCommand -NoLogo -NoProfile -NonInteractive -File $cliPath clean --wait-seconds 1 --home $temporaryHome --repository $fixtureRoot *> $null
        }
        foreach ($path in @($fixtureRoot, $temporaryHome)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

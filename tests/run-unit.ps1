[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "..\src\AgentLocalCI\AgentLocalCI.psm1"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
Import-Module $modulePath -Force
$module = Get-Module AgentLocalCI
$passed = 0
$failed = 0
$failures = [Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:passed++
        Write-Output "PASS $Name"
    }
    catch {
        $script:failed++
        $script:failures.Add("$Name`: $($_.Exception.Message)")
        Write-Output "FAIL $Name"
    }
}

Test-Case "version command is stable" {
    $result = @(& $module { Invoke-AgentLocalCiCli @("version") })
    Assert-Equal $result[-1] 0 "version exit code"
    Assert-True ([string]$result[0] -match '^AgentLocalCI 0\.2\.0-beta\.1') "version output"
}

Test-Case "redaction removes credentials and private host identity" {
    $tokenPrefix = 'github' + '_pat_'
    $fakeToken = $tokenPrefix + ('1' * 30)
    $bearerValue = 'abcdefghijklmnopqrstuvwxyz' + '123456'
    $slash = [char]92
    $userPath = 'C:' + $slash + 'Users' + $slash + 'example-user' + $slash + 'private-project'
    $email = 'owner' + '@' + 'example.invalid'
    $privateIp = @('192', '168', '1', '15') -join '.'
    $input = "token=$fakeToken Bearer $bearerValue $userPath $email $privateIp"
    $value = & $module { param($text) ConvertTo-AgentLocalCiRedactedText $text } $input
    Assert-True ($value -notmatch [Regex]::Escape($tokenPrefix)) "credential prefix survived"
    Assert-True ($value -notmatch [Regex]::Escape($bearerValue)) "Bearer value survived"
    Assert-True ($value -notmatch 'example-user|private-project|owner@example|192\.168\.1\.15') "private identity or path data survived"
    Assert-True ($value -match '<redacted') "redaction marker missing"
}

Test-Case "stream redaction handles split chunks and overlong lines" {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-redaction-" + [Guid]::NewGuid().ToString('N') + '.log')
    $writer = $null
    try {
        $writer = [IO.StreamWriter]::new($path, $false, [Text.UTF8Encoding]::new($false))
        $slot = [pscustomobject]@{ Writer = $writer; Carry = ""; DiscardingLine = $false }
        $tokenPrefix = 'github' + '_pat_'
        $untrustedLine = 'token=' + $tokenPrefix + ('2' * 30) + "`n"
        $splitAt = 19
        & $module { param($s,$chunk) Write-AgentLocalCiRedactedStreamChunk $s $chunk } $slot $untrustedLine.Substring(0, $splitAt)
        & $module { param($s,$chunk) Write-AgentLocalCiRedactedStreamChunk $s $chunk } $slot $untrustedLine.Substring($splitAt)
        & $module { param($s) Write-AgentLocalCiRedactedStreamChunk $s ('x' * 200) -MaximumLineCharacters 64 -EndOfStream } $slot
        $writer.Flush()
        $writer.Dispose()
        $writer = $null
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        Assert-True ($text -notmatch [Regex]::Escape($tokenPrefix)) "split secret survived"
        Assert-True ($text -match 'discarded an overlong') "overlong line was not bounded"
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

Test-Case "relative paths allow repository root but reject traversal and quotes" {
    Assert-True (& $module { Test-AgentLocalCiSafeRelativePath '.' }) "dot root should be allowed"
    Assert-True (-not (& $module { Test-AgentLocalCiSafeRelativePath '../escape' })) "traversal accepted"
    Assert-True (-not (& $module { Test-AgentLocalCiSafeRelativePath "folder/'quoted'" })) "quote accepted"
}

Test-Case "default policy is safe and rejects privileged downgrade" {
    $policy = & $module { New-AgentLocalCiDefaultPolicy }
    $validated = & $module { param($p) Assert-AgentLocalCiPolicy $p } $policy
    Assert-Equal $validated.executor 'docker' "executor"
    Assert-True (-not [bool]$validated.allow_privileged) "default policy permits privileged execution"
    Assert-True (-not [bool]$validated.allow_docker_socket) "default policy permits Docker socket access"
    Assert-True (-not [bool]$validated.allow_secrets) "default policy permits secrets"

    $unsafe = $policy | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $unsafe.allow_privileged = $true
    $blocked = $false
    try { & $module { param($p) Assert-AgentLocalCiPolicy $p } $unsafe | Out-Null } catch { $blocked = $true }
    Assert-True $blocked "privileged policy was accepted"
}

Test-Case "pipeline validator rejects shell property and secret environment names" {
    $policy = & $module { New-AgentLocalCiDefaultPolicy }
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

    $pipeline = & $module { Get-AgentLocalCiDefaultPipelineObject }
    $pipeline.profiles.standard.stages[0] | Add-Member -NotePropertyName shell -NotePropertyValue 'npm run lint'
    $blocked = $false
    try { & $module { param($p,$m,$r) Assert-AgentLocalCiPipeline $p $m $r } $pipeline $policy $repositoryRoot | Out-Null } catch { $blocked = $true }
    Assert-True $blocked "shell property was accepted"

    $pipeline = & $module { Get-AgentLocalCiDefaultPipelineObject }
    $pipeline.environment = [pscustomobject]@{ API_TOKEN = 'example' }
    $blocked = $false
    try { & $module { param($p,$m,$r) Assert-AgentLocalCiPipeline $p $m $r } $pipeline $policy $repositoryRoot | Out-Null } catch { $blocked = $true }
    Assert-True $blocked "secret environment name was accepted"
}

Test-Case "container arguments enforce unprivileged read-only offline shape" {
    $policy = & $module { New-AgentLocalCiDefaultPolicy }
    $context = [pscustomobject]@{ Policy = $policy }
    $args = & $module { param($c) New-AgentLocalCiContainerBaseArguments $c 'alc-123456789012-test' '20260827-123456789-123456789012' 'test' 'none' } $context
    $joined = $args -join ' '
    Assert-True ($joined -match '--user 10001:10001') "UID missing"
    Assert-True ($joined -match '--read-only') "read-only missing"
    Assert-True ($joined -match '--cap-drop ALL') "cap drop missing"
    Assert-True ($joined -match '--security-opt no-new-privileges:true') "no-new-privileges missing"
    Assert-True ($joined -match '--network none') "network none missing"
    Assert-True ($joined -notmatch '--privileged|type=bind|docker\.sock') "unsafe option present"
}

Test-Case "exact revision rejects names abbreviations and uppercase" {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-git-" + [Guid]::NewGuid().ToString('N'))
    try {
        & git init -q -b main $root
        [IO.File]::WriteAllText((Join-Path $root 'a.txt'), 'one')
        & git -C $root add a.txt
        & git -C $root -c user.name=Test -c user.email=test@example.invalid commit -q -m one
        $sha = (& git -C $root rev-parse HEAD).Trim()
        Assert-Equal (& $module { param($r,$s) Resolve-AgentLocalCiCommit $r $s } $root $sha) $sha "exact SHA"
        foreach ($invalid in @('HEAD', $sha.Substring(0,12), $sha.ToUpperInvariant())) {
            $blocked = $false
            try { & $module { param($r,$s) Resolve-AgentLocalCiCommit $r $s } $root $invalid | Out-Null } catch { $blocked = $true }
            Assert-True $blocked "invalid revision '$invalid' was accepted"
        }
    }
    finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Test-Case "provenance pack contains exact tree but not parent commit" {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-pack-" + [Guid]::NewGuid().ToString('N'))
    $temporaryHome = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-home-" + [Guid]::NewGuid().ToString('N'))
    try {
        & git init -q -b main $root
        [IO.File]::WriteAllText((Join-Path $root 'a.txt'), 'one')
        & git -C $root add a.txt
        & git -C $root -c user.name=Test -c user.email=test@example.invalid commit -q -m one
        $parent = (& git -C $root rev-parse HEAD).Trim()
        [IO.File]::WriteAllText((Join-Path $root 'b.txt'), 'two')
        & git -C $root add b.txt
        & git -C $root -c user.name=Test -c user.email=test@example.invalid commit -q -m two
        $sha = (& git -C $root rev-parse HEAD).Trim()
        $scratch = Join-Path $temporaryHome 'scratch'
        [IO.Directory]::CreateDirectory($scratch) | Out-Null
        $context = [pscustomobject]@{ RepositoryRoot = $root }
        $pack = & $module { param($c,$s,$d) New-AgentLocalCiProvenancePack $c $s $d } $context $sha $scratch
        Assert-True (Test-Path -LiteralPath $pack.Path) "pack missing"
        Assert-True (-not [bool]$pack.HistoryIncluded) "history flag"
        $verify = & git verify-pack -v $pack.IndexPath | Out-String
        Assert-True ($verify -notmatch [Regex]::Escape($parent)) "parent commit leaked into pack"
    }
    finally {
        foreach ($path in @($root, $temporaryHome)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    }
}

Test-Case "pipeline rejects command-string interpreters and secret-like argv" {
    $policy = & $module { New-AgentLocalCiDefaultPolicy }
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

    $pipeline = & $module { Get-AgentLocalCiDefaultPipelineObject }
    $pipeline.profiles.standard.stages[0].command = @('bash', '-c', 'echo unsafe')
    $blocked = $false
    try { & $module { param($p,$m,$r) Assert-AgentLocalCiPipeline $p $m $r } $pipeline $policy $repositoryRoot | Out-Null } catch { $blocked = $true }
    Assert-True $blocked "bash command string was accepted"

    $pipeline = & $module { Get-AgentLocalCiDefaultPipelineObject }
    $fakeToken = ('github' + '_pat_') + ('3' * 30)
    $pipeline.profiles.standard.stages[0].command = @('tool', $fakeToken)
    $blocked = $false
    try { & $module { param($p,$m,$r) Assert-AgentLocalCiPipeline $p $m $r } $pipeline $policy $repositoryRoot | Out-Null } catch { $blocked = $true }
    Assert-True $blocked "secret-like argv was accepted"
}

Test-Case "sensitive environment matching avoids PATH false positives" {
    Assert-True (-not (& $module { Test-AgentLocalCiSensitiveEnvironmentName 'PATH' })) "PATH was treated as a PAT secret"
    Assert-True (& $module { Test-AgentLocalCiSensitiveEnvironmentName 'GITHUB_TOKEN' }) "GITHUB_TOKEN was not blocked"
}

Test-Case "empty resource recovery is valid and ownership records are strict" {
    $runId = '20260827-123456789-123456789012'
    $emptyA = [Collections.Generic.List[object]]::new()
    $emptyB = [Collections.Generic.List[object]]::new()
    $merged = & $module { param($a,$b,$r) Merge-AgentLocalCiRunResources $a $b $r } $emptyA $emptyB $runId
    Assert-Equal $merged.Count 0 "empty recovery merge"
    $valid = [pscustomobject]@{ Type = 'volume'; Name = 'alc-123456789012-cache'; Kind = 'npm-cache'; RunId = $runId }
    Assert-True (& $module { param($x,$r) Test-AgentLocalCiTrackedResourceShape $x $r } $valid $runId) "valid ownership record was rejected"
    $valid.Kind = ''
    Assert-True (-not (& $module { param($x,$r) Test-AgentLocalCiTrackedResourceShape $x $r } $valid $runId)) "empty resource kind was accepted"
}

Test-Case "path containment handles a filesystem root without doubled separator" {
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))
    $child = Join-Path $root 'agentlocalci-contained'
    Assert-True (& $module { param($c,$r) Test-AgentLocalCiPathContained $c $r } $child $root) "filesystem-root containment failed"
}

Test-Case "Docker network gateway parsing tolerates omitted fields" {
    $inspection = [pscustomobject]@{
        IPAM = [pscustomobject]@{
            Config = @(
                [pscustomobject]@{ Subnet = '172.30.0.0/16' },
                [pscustomobject]@{ Subnet = '172.31.0.0/16'; Gateway = '172.31.0.1' }
            )
        }
    }
    $gateways = @(& $module { param($x) Get-AgentLocalCiDockerNetworkGateways $x } $inspection)
    Assert-Equal $gateways.Count 1 "gateway count"
    Assert-Equal $gateways[0] '172.31.0.1' "gateway value"
}

Test-Case "Docker resources are registered before create-time failures" {
    $cases = @(
        [pscustomobject]@{ Function = 'New-AgentLocalCiDockerVolume'; CreateMarker = 'Invoke-AgentLocalCiDocker (@("volume", "create")' },
        [pscustomobject]@{ Function = 'New-AgentLocalCiDockerNetwork'; CreateMarker = '$arguments = @("network", "create"' },
        [pscustomobject]@{ Function = 'New-AgentLocalCiTrackedContainer'; CreateMarker = '$created = Invoke-AgentLocalCiDocker $Arguments' }
    )
    foreach ($case in $cases) {
        $text = & $module { param($name) (Get-Command $name).ScriptBlock.ToString() } $case.Function
        $recordIndex = $text.IndexOf('$Resources.Add', [StringComparison]::Ordinal)
        $createIndex = $text.IndexOf($case.CreateMarker, [StringComparison]::Ordinal)
        Assert-True ($recordIndex -ge 0) "$($case.Function) has no ownership pre-registration"
        Assert-True ($createIndex -gt $recordIndex) "$($case.Function) creates before ownership pre-registration"
    }
}

Test-Case "runtime inspector accepts a container with zero expected volumes" {
    $hasAllowEmpty = & $module {
        @((Get-Command Assert-AgentLocalCiRuntimeContainer).Parameters['ExpectedVolumes'].Attributes | Where-Object { $_ -is [Management.Automation.AllowEmptyCollectionAttribute] }).Count -eq 1
    }
    Assert-True $hasAllowEmpty "ExpectedVolumes rejects the valid empty-volume proxy boundary"
}

Test-Case "trusted runner exits have distinct safety and infrastructure classes" {
    $targetFailure = [pscustomobject]@{ ExitCode = 7; TimedOut = $false; OutputLimitExceeded = $false }
    $safety = [pscustomobject]@{ ExitCode = 200; TimedOut = $false; OutputLimitExceeded = $false }
    $infrastructure = [pscustomobject]@{ ExitCode = 210; TimedOut = $false; OutputLimitExceeded = $false }
    Assert-Equal (& $module { param($x) Get-AgentLocalCiStageStatus $x } $targetFailure) 'Failed' "target failure status"
    Assert-Equal (& $module { param($x) Get-AgentLocalCiStageStatus $x } $safety) 'SafetyBlocked' "safety status"
    Assert-Equal (& $module { param($x) Get-AgentLocalCiStageStatus $x } $infrastructure) 'InfrastructureFailed' "infrastructure status"
}

Test-Case "repository root accepts Git-canonical aliases and rejects subdirectories" {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-root-canonical-" + [Guid]::NewGuid().ToString('N'))
    try {
        & git init -q -b main $root
        $expected = [IO.Path]::GetFullPath((& git -C $root rev-parse --show-toplevel).Trim())
        $actual = & $module { param($r) Get-AgentLocalCiRepositoryRoot $r } $root
        Assert-Equal $actual $expected "repository root was not normalized to Git's canonical top level"

        $child = Join-Path $root 'nested'
        [IO.Directory]::CreateDirectory($child) | Out-Null
        $blocked = $false
        try { & $module { param($r) Get-AgentLocalCiRepositoryRoot $r | Out-Null } $child } catch { $blocked = $true }
        Assert-True $blocked "repository subdirectory was accepted as the worktree root"
    }
    finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

Test-Case "Gradle init starter includes wrapper redirect hosts" {
    $requiredHosts = @('services.gradle.org', 'github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com')
    if ($false) {
        $definition = & $module { (Get-Command Initialize-AgentLocalCiRepository).ScriptBlock.ToString() }
        foreach ($hostName in $requiredHosts) {
            Assert-True ($definition.Contains('"' + $hostName + '"', [StringComparison]::Ordinal)) "Gradle starter omitted $hostName"
        }
        return
    }

    $root = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-init-gradle-" + [Guid]::NewGuid().ToString('N'))
    $temporaryHome = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-init-home-" + [Guid]::NewGuid().ToString('N'))
    try {
        & git init -q -b main $root
        [IO.File]::WriteAllText((Join-Path $root 'gradlew'), '#!/usr/bin/env sh')
        [void](& $module { param($h,$r) Initialize-AgentLocalCiRepository $h $r $null } $temporaryHome $root)
        $pipeline = Get-Content -LiteralPath (Join-Path $root '.agentlocalci\pipeline.yml') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50
        foreach ($hostName in $requiredHosts) {
            Assert-True (@($pipeline.dependency_hosts) -ccontains $hostName) "Gradle starter omitted $hostName"
        }
    }
    finally {
        foreach ($path in @($root, $temporaryHome)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    }
}

Test-Case "macOS system aliases canonicalize narrowly while arbitrary links remain blocked" {
    if (-not $IsMacOS) { return }

    $lexical = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-alias-" + [Guid]::NewGuid().ToString('N'))
    $canonical = & $module { param($p) Assert-AgentLocalCiPathIsNarrow $p } $lexical
    if ($lexical.StartsWith('/var/', [StringComparison]::Ordinal)) {
        Assert-True ($canonical.StartsWith('/private/var/', [StringComparison]::Ordinal)) "trusted /var alias was not canonicalized"
    }

    $base = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) (".agentlocalci-link-test-" + [Guid]::NewGuid().ToString('N'))
    $target = Join-Path $base 'target'
    $link = Join-Path $base 'link'
    try {
        [IO.Directory]::CreateDirectory($target) | Out-Null
        New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
        $blocked = $false
        try { & $module { param($p) Assert-AgentLocalCiPathIsNarrow $p | Out-Null } (Join-Path $link 'nested') } catch { $blocked = $true }
        Assert-True $blocked "project-controlled symbolic-link ancestor was accepted"
    }
    finally {
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
        if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
    }
}

Test-Case "controller identity matches installer inventory boundary" {
    $moduleRoot = Split-Path -Parent $modulePath
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $product = Get-Content -LiteralPath (Join-Path $moduleRoot 'product.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $inventory = [Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($file in @(Get-ChildItem -LiteralPath $moduleRoot -File -Recurse | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($moduleRoot, $file.FullName).Replace([char]92, '/')
        $inventory.Add("src/AgentLocalCI/$relative", (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    $cliPath = Join-Path $repositoryRoot 'bin\agentlocalci.ps1'
    $inventory.Add('bin/agentlocalci.ps1', (Get-FileHash -LiteralPath $cliPath -Algorithm SHA256).Hash.ToLowerInvariant())
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add("AgentLocalCI/$($product.version)")
    foreach ($entry in $inventory.GetEnumerator()) { $parts.Add("$($entry.Key):$($entry.Value)") }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $expected = (($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($parts -join "`n")) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,20)
    }
    finally { $algorithm.Dispose() }
    $actual = & $module { Get-AgentLocalCiControllerIdentity ([pscustomobject]@{}) }
    Assert-Equal $actual $expected "controller identity does not match installer inventory"
}

Test-Case "platform abstraction exposes a safe supported host contract" {
    $platform = & $module { Get-AgentLocalCiHostPlatform }
    Assert-True ($platform -in @('windows', 'macos', 'linux')) "unsupported test host"
    $nullDevice = & $module { Get-AgentLocalCiNullDevice }
    Assert-Equal $nullDevice $(if ($platform -ceq 'windows') { 'NUL' } else { '/dev/null' }) "null device"
    $defaultHome = & $module { Get-AgentLocalCiDefaultHome }
    Assert-True ([IO.Path]::IsPathRooted($defaultHome)) "default home is not absolute"
    $memory = & $module { Get-AgentLocalCiRecommendedMemoryGiB }
    Assert-True ($memory -ge 4 -and $memory -le 16) "recommended memory is outside the bounded policy"
}

Test-Case "trusted image definition is native multi-architecture and checksum pinned" {
    $dockerfile = Get-Content -LiteralPath (Join-Path $repoRoot 'src/AgentLocalCI/Container/Dockerfile') -Raw -Encoding UTF8
    foreach ($required in @(
        'ARG TARGETARCH',
        'sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517',
        'NODE_SHA256_ARM64=1bf1eb9ee63ffc4e5d324c0b9b62cf4a289f44332dfef9607cea1a0d9596ba6f',
        'POWERSHELL_SHA256_ARM64=d4ef2382fa452f2ccbdb48a01adbbce9ed64954872123970c16be6d086d1224b',
        'io.agentlocalci.arch'
    )) { Assert-True ($dockerfile.Contains($required, [StringComparison]::Ordinal)) "Dockerfile omitted $required" }
}

Test-Case "beginner why command is balanced rather than anti-hosted-CI marketing" {
    $result = @(& $module { Invoke-AgentLocalCiCli @('why') })
    Assert-Equal $result[-1] 0 "why exit code"
    $text = ($result[0..($result.Count - 2)] -join "`n")
    Assert-True ($text -match 'GitHub Actions') "why output omitted GitHub Actions"
    Assert-True ($text -match 'Keep GitHub Actions') "why output omitted hosted-CI use cases"
    Assert-True ($text -match 'exact-commit|exact commit') "why output omitted exact-commit value"
}

Test-Case "smart npm setup detects only scripts that actually exist" {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-init-npm-" + [Guid]::NewGuid().ToString('N'))
    $temporaryHome = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-init-npm-home-" + [Guid]::NewGuid().ToString('N'))
    try {
        & git init -q -b main $root
        [IO.File]::WriteAllText((Join-Path $root 'package.json'), '{"name":"sample","scripts":{"lint":"eslint .","test":"node test.mjs","build":"node build.mjs","unused":"echo unused"}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'package-lock.json'), '{"name":"sample","lockfileVersion":3,"packages":{}}', [Text.UTF8Encoding]::new($false))
        $setup = & $module { param($h,$r) Initialize-AgentLocalCiRepository $h $r $null } $temporaryHome $root
        Assert-Equal $setup.Detected 'npm' "detected project"
        Assert-True ($setup.Acceptance) "npm standard profile is not acceptance"
        Assert-True ((@($setup.Stages) -join ',') -ceq 'lint,test,build') "detected stages differ"
        $pipeline = Get-Content -LiteralPath (Join-Path $root '.agentlocalci/pipeline.yml') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50
        $commands = @($pipeline.profiles.standard.stages | ForEach-Object { $_.command -join ' ' }) -join ';'
        Assert-True ($commands -notmatch 'eslint \.|node test\.mjs|echo unused') "raw package script content was embedded"
        Assert-True ($commands -match 'npm run lint' -and $commands -match 'npm test' -and $commands -match 'npm run build') "safe npm argv was not generated"
    }
    finally {
        foreach ($path in @($root, $temporaryHome)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
}

Test-Case "easy check resolves exact HEAD and refuses dirty source" {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-check-" + [Guid]::NewGuid().ToString('N'))
    try {
        & git init -q -b main $root
        [IO.File]::WriteAllText((Join-Path $root 'a.txt'), 'one')
        & git -C $root add a.txt
        & git -C $root -c user.name=Test -c user.email=test@example.invalid commit -q -m one
        $expected = (& git -C $root rev-parse HEAD).Trim()
        $actual = & $module { param($r) Get-AgentLocalCiExactHead $r } $root
        Assert-Equal $actual $expected "exact HEAD"
        & $module { param($r) Assert-AgentLocalCiWorkingTreeClean $r } $root
        [IO.File]::WriteAllText((Join-Path $root 'dirty.txt'), 'dirty')
        $blocked = $false
        try { & $module { param($r) Assert-AgentLocalCiWorkingTreeClean $r } $root } catch { $blocked = $true }
        Assert-True $blocked "dirty working tree was accepted"
    }
    finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

Test-Case "pre-push hook is opt-in owned and non-destructive" {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-hook-" + [Guid]::NewGuid().ToString('N'))
    try {
        & git init -q -b main $root
        [IO.File]::WriteAllText((Join-Path $root 'a.txt'), 'one')
        & git -C $root add a.txt
        & git -C $root -c user.name=Test -c user.email=test@example.invalid commit -q -m one
        $installed = & $module { param($r) Install-AgentLocalCiPrePushHook $r 'fast' } $root
        Assert-True ($installed.Installed -and $installed.Owned -and $installed.Profile -ceq 'fast') "owned hook was not installed"
        $content = Get-Content -LiteralPath $installed.Path -Raw -Encoding UTF8
        Assert-True ($content -match 'agentlocalci check' -and $content -notmatch [Regex]::Escape($repoRoot)) "hook is missing check or leaked a local source path"
        $removed = & $module { param($r) Remove-AgentLocalCiPrePushHook $r } $root
        Assert-True $removed.Removed "owned hook was not removed"
        [IO.Directory]::CreateDirectory((Split-Path -Parent $installed.Path)) | Out-Null
        [IO.File]::WriteAllText($installed.Path, '#!/bin/sh' + "`n" + 'echo foreign' + "`n", [Text.UTF8Encoding]::new($false))
        $blocked = $false
        try { & $module { param($r) Install-AgentLocalCiPrePushHook $r 'fast' | Out-Null } $root } catch { $blocked = $true }
        Assert-True $blocked "foreign hook was overwritten"
        Assert-True ((Get-Content -LiteralPath $installed.Path -Raw -Encoding UTF8) -match 'foreign') "foreign hook content changed"
        Remove-Item -LiteralPath $installed.Path -Force
        & git -C $root config --local core.hooksPath custom-hooks
        $blocked = $false
        try { & $module { param($r) Install-AgentLocalCiPrePushHook $r 'fast' | Out-Null } $root } catch { $blocked = $true }
        Assert-True $blocked "custom core.hooksPath was mutated or ignored"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'custom-hooks/pre-push'))) "custom hook path was written"
    }
    finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

Test-Case "HTML report is self-contained escaped and human-readable" {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("agentlocalci-report-" + [Guid]::NewGuid().ToString('N') + '.html')
    try {
        $report = [pscustomobject]@{
            result='Passed'; project='<demo>'; run_id='20260827-123456789-123456789012'; target_sha=('a' * 40); duration_seconds=1.2
            host=[pscustomobject]@{platform='macos';architecture='arm64'}
            profile=[pscustomobject]@{name='standard';gaps=@('No deployment.')}
            stages=@([pscustomobject]@{id='test';status='Passed';duration_seconds=1.0;exit_code=0;stdout_log='01-test.stdout.log'})
            security=[pscustomobject]@{validation_network='none';exact_tree_source=$true;host_mounts=$false;credentials_forwarded=$false}
            cleanup=[pscustomobject]@{status='Passed'}
            image=[pscustomobject]@{id='sha256:' + ('b' * 64);architecture='arm64'}
            error=''
        }
        & $module { param($p,$r) Write-AgentLocalCiHtmlReport $p $r } $path $report
        $html = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        Assert-True ($html -match '&lt;demo&gt;' -and $html -notmatch '<demo>') "project name was not HTML escaped"
        Assert-True ($html -notmatch '(?i)<script|https?://') "HTML report contains active or external content"
        Assert-True ($html -match 'Validation network' -and $html -match 'Exact-tree source') "safety summary missing"
    }
    finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}

Test-Case "CLI rejects unknown options" {
    $result = @(& $module { Invoke-AgentLocalCiCli @('version', '--surprise') })
    Assert-Equal $result[-1] 2 "unknown-option exit code"
}

Write-Output "RESULT passed=$passed failed=$failed"
if ($failed -gt 0) {
    foreach ($failure in $failures) { [Console]::Error.WriteLine($failure) }
    exit 1
}
exit 0

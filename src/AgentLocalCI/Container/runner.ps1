[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9+/=]+$')]
    [string]$JobBase64
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Fail([string]$Message, [int]$Code = 210) {
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Is-Contained([string]$Path, [string]$Parent) {
    $child = [IO.Path]::GetFullPath($Path).TrimEnd('/')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('/')
    return $child -ceq $root -or $child.StartsWith("$root/", [StringComparison]::Ordinal)
}

function Resolve-CanonicalPath([string]$Path, [string]$Description) {
    $output = @(& /usr/bin/readlink -f -- $Path 2>$null | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    $resolved = ($output -join "`n").Trim()
    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($resolved) -or -not [IO.Path]::IsPathRooted($resolved)) {
        Fail "AgentLocalCI could not resolve the canonical $Description" 200
    }
    return [IO.Path]::GetFullPath($resolved).TrimEnd('/')
}

function Is-SafeRelativePath([string]$Path) {
    if (
        [string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or
        $Path.Contains('"') -or $Path.Contains("'") -or $Path.Contains(':') -or
        $Path -match '[\x00-\x1F\x7F]'
    ) { return $false }
    if ($Path -ceq '.') { return $true }
    $normalized = $Path.Replace('\', '/')
    foreach ($segment in @($normalized -split '/')) { if ($segment -in @('', '.', '..')) { return $false } }
    return $true
}

function New-ChildStartInfo([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [object]$Environment) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    foreach ($argument in $Arguments) { [void]$info.ArgumentList.Add($argument) }
    $fixed = [ordered]@{
        PATH = [Environment]::GetEnvironmentVariable('PATH', 'Process')
        HOME = '/home/ci'
        CI = 'true'
        LANG = 'C.UTF-8'
        LC_ALL = 'C.UTF-8'
        JAVA_HOME = '/opt/java-home'
        ANDROID_HOME = '/opt/android-sdk'
        ANDROID_SDK_ROOT = '/opt/android-sdk'
        NEXT_TELEMETRY_DISABLED = '1'
        NPM_CONFIG_UPDATE_NOTIFIER = 'false'
        AGENTLOCALCI_EXECUTION_BOUNDARY = 'unprivileged-linux-container'
        AGENTLOCALCI_ARTIFACT_ROOT = '/evidence'
    }
    $info.Environment.Clear()
    foreach ($entry in $fixed.GetEnumerator()) { $info.Environment[$entry.Key] = [string]$entry.Value }
    if ($null -ne $Environment) {
        foreach ($property in $Environment.PSObject.Properties) { $info.Environment[$property.Name] = [string]$property.Value }
    }
    return $info
}

function Invoke-Child([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [object]$Environment) {
    $display = @([IO.Path]::GetFileName($FilePath)) + @($Arguments)
    [Console]::Out.WriteLine("AgentLocalCI argv: " + (($display | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '))
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = New-ChildStartInfo $FilePath $Arguments $WorkingDirectory $Environment
    try {
        if (-not $process.Start()) { Fail "AgentLocalCI failed to start the child process" 210 }
        $process.WaitForExit()
        return [int]$process.ExitCode
    }
    finally { $process.Dispose() }
}

function Get-ExternalChildExitCode([int]$Code) {
    if ($Code -ge 200 -and $Code -le 219) {
        [Console]::Error.WriteLine("AgentLocalCI remapped a target process exit code reserved for the trusted runner.")
        return 1
    }
    return $Code
}

if ([Environment]::UserName -eq 'root' -or [Environment]::GetEnvironmentVariable('AGENTLOCALCI_EXECUTION_BOUNDARY') -cne 'unprivileged-linux-container') {
    Fail "AgentLocalCI runner boundary is invalid" 200
}
if ([Environment]::GetEnvironmentVariable('AGENTLOCALCI_ARTIFACT_ROOT') -cne '/evidence') { Fail "AgentLocalCI artifact boundary is invalid" 200 }

try {
    $jobText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($JobBase64))
    if ($jobText.Length -gt 1MB) { Fail "AgentLocalCI job exceeds its bound" 200 }
    $job = $jobText | ConvertFrom-Json -Depth 50
}
catch { Fail "AgentLocalCI job document is invalid" 200 }

$required = @('sha', 'tree', 'stage_id', 'command', 'working_directory', 'needs', 'environment', 'dependencies', 'gradle_max_workers')
foreach ($name in $required) { if ($null -eq $job.PSObject.Properties[$name]) { Fail "AgentLocalCI job is missing '$name'" 200 } }
if (
    [string]$job.sha -cnotmatch '^[0-9a-f]{40}$' -or
    [string]$job.tree -cnotmatch '^[0-9a-f]{40}$' -or
    [string]$job.stage_id -cnotmatch '^[a-z][a-z0-9-]{0,63}$'
) { Fail "AgentLocalCI job identity is invalid" 200 }
if ([Environment]::GetEnvironmentVariable('AGENTLOCALCI_TARGET_SHA') -cne [string]$job.sha) { Fail "AgentLocalCI target SHA marker does not match the job" 200 }
if ([Environment]::GetEnvironmentVariable('AGENTLOCALCI_TARGET_TREE') -cne [string]$job.tree) { Fail "AgentLocalCI target tree marker does not match the job" 200 }

$repo = '/workspace/repo'
if (-not (Test-Path -LiteralPath $repo -PathType Container)) { Fail "AgentLocalCI exact-tree workspace is missing" 200 }
if (Test-Path -LiteralPath "$repo/.git") { Fail "AgentLocalCI validation workspace contains forbidden Git metadata" 200 }
$commitMarkerPath = '/workspace/.agentlocalci-commit'
$treeMarkerPath = '/workspace/.agentlocalci-tree'
if (-not (Test-Path -LiteralPath $commitMarkerPath -PathType Leaf) -or -not (Test-Path -LiteralPath $treeMarkerPath -PathType Leaf)) { Fail "AgentLocalCI exact-tree provenance markers are missing" 200 }
$commitMarker = (Get-Content -LiteralPath $commitMarkerPath -Raw -Encoding UTF8).Trim()
$treeMarker = (Get-Content -LiteralPath $treeMarkerPath -Raw -Encoding UTF8).Trim()
if ($commitMarker -cne [string]$job.sha -or $treeMarker -cne [string]$job.tree) { Fail "AgentLocalCI exact-tree provenance markers do not match the job" 200 }
$canonicalRepo = Resolve-CanonicalPath $repo 'repository root'
if ($canonicalRepo -cne $repo) { Fail "AgentLocalCI repository root resolved outside its fixed mount" 200 }
if (-not (Is-SafeRelativePath ([string]$job.working_directory))) { Fail "AgentLocalCI working directory is unsafe" 200 }
$workingDirectoryCandidate = [IO.Path]::GetFullPath((Join-Path $repo ([string]$job.working_directory)))
if (-not (Test-Path -LiteralPath $workingDirectoryCandidate -PathType Container)) { Fail "AgentLocalCI working directory is missing" 200 }
$workingDirectory = Resolve-CanonicalPath $workingDirectoryCandidate 'working directory'
if (-not (Is-Contained $workingDirectory $canonicalRepo)) { Fail "AgentLocalCI working directory escaped the exact tree through a symbolic link" 200 }

$needs = @($job.needs | ForEach-Object { [string]$_ })
foreach ($need in $needs) { if ($need -notin @('npm', 'gradle')) { Fail "AgentLocalCI dependency need is unsupported" 200 } }
$childEnvironment = [ordered]@{}
foreach ($property in $job.environment.PSObject.Properties) { $childEnvironment[$property.Name] = [string]$property.Value }
$childEnvironment.AGENTLOCALCI_TARGET_SHA = [string]$job.sha
$childEnvironment.AGENTLOCALCI_TARGET_TREE = [string]$job.tree
$childEnvironment.AGENTLOCALCI_STAGE_ID = [string]$job.stage_id

if ($needs -contains 'npm') {
    $npm = $job.dependencies.npm
    if ($null -eq $npm -or -not (Is-SafeRelativePath ([string]$npm.working_directory)) -or -not (Is-SafeRelativePath ([string]$npm.lockfile))) { Fail "AgentLocalCI npm dependency definition is invalid" 200 }
    $npmDirectoryCandidate = [IO.Path]::GetFullPath((Join-Path $repo ([string]$npm.working_directory)))
    $lockfileCandidate = [IO.Path]::GetFullPath((Join-Path $npmDirectoryCandidate ([string]$npm.lockfile)))
    if (-not (Test-Path -LiteralPath $npmDirectoryCandidate -PathType Container) -or -not (Test-Path -LiteralPath $lockfileCandidate -PathType Leaf)) { Fail "AgentLocalCI npm directory or lockfile is missing" 200 }
    $npmDirectory = Resolve-CanonicalPath $npmDirectoryCandidate 'npm working directory'
    $lockfile = Resolve-CanonicalPath $lockfileCandidate 'npm lockfile'
    if (-not (Is-Contained $npmDirectory $canonicalRepo) -or -not (Is-Contained $lockfile $canonicalRepo)) { Fail "AgentLocalCI npm directory or lockfile escaped the exact tree through a symbolic link" 200 }
    [IO.File]::WriteAllText('/tmp/npm-userconfig', '')
    [IO.File]::WriteAllText('/tmp/npm-globalconfig', '')
    $npmEnvironment = [pscustomobject]@{
        NPM_CONFIG_USERCONFIG = '/tmp/npm-userconfig'
        NPM_CONFIG_GLOBALCONFIG = '/tmp/npm-globalconfig'
        NPM_CONFIG_CACHE = '/npm-cache'
        NPM_CONFIG_OFFLINE = 'true'
    }
    $npmExit = Get-ExternalChildExitCode (Invoke-Child 'npm' @('ci', '--ignore-scripts', '--offline', '--no-audit', '--no-fund') $npmDirectory $npmEnvironment)
    if ($npmExit -ne 0) { exit $npmExit }
    $childEnvironment.NPM_CONFIG_USERCONFIG = '/tmp/npm-userconfig'
    $childEnvironment.NPM_CONFIG_GLOBALCONFIG = '/tmp/npm-globalconfig'
    $childEnvironment.NPM_CONFIG_CACHE = '/npm-cache'
    $childEnvironment.NPM_CONFIG_OFFLINE = 'true'
}

if ($needs -contains 'gradle') {
    $gradle = $job.dependencies.gradle
    if ($null -eq $gradle -or -not (Is-SafeRelativePath ([string]$gradle.working_directory)) -or -not (Is-SafeRelativePath ([string]$gradle.wrapper))) { Fail "AgentLocalCI Gradle dependency definition is invalid" 200 }
    $gradleDirectoryCandidate = [IO.Path]::GetFullPath((Join-Path $repo ([string]$gradle.working_directory)))
    $wrapperCandidate = [IO.Path]::GetFullPath((Join-Path $gradleDirectoryCandidate ([string]$gradle.wrapper)))
    if (-not (Test-Path -LiteralPath $gradleDirectoryCandidate -PathType Container) -or -not (Test-Path -LiteralPath $wrapperCandidate -PathType Leaf)) { Fail "AgentLocalCI Gradle directory or wrapper is missing" 200 }
    $gradleDirectory = Resolve-CanonicalPath $gradleDirectoryCandidate 'Gradle working directory'
    $wrapper = Resolve-CanonicalPath $wrapperCandidate 'Gradle wrapper'
    if (-not (Is-Contained $gradleDirectory $canonicalRepo) -or -not (Is-Contained $wrapper $canonicalRepo)) { Fail "AgentLocalCI Gradle directory or wrapper escaped the exact tree through a symbolic link" 200 }
    $childEnvironment.GRADLE_USER_HOME = '/gradle'
}

$command = @($job.command | ForEach-Object { [string]$_ })
if ($command.Count -lt 1 -or [string]::IsNullOrWhiteSpace($command[0])) { Fail "AgentLocalCI command argv is empty" 200 }
$executable = $command[0]
$arguments = @($command | Select-Object -Skip 1)
if ($executable.Contains('/') -or $executable.Contains('\')) {
    if ([IO.Path]::IsPathRooted($executable)) {
        if (-not ($executable.StartsWith('/usr/', [StringComparison]::Ordinal) -or $executable.StartsWith('/bin/', [StringComparison]::Ordinal) -or $executable.StartsWith('/opt/android-sdk/', [StringComparison]::Ordinal))) { Fail "AgentLocalCI absolute executable is outside the trusted toolchain" 200 }
    }
    else {
        $executableCandidate = [IO.Path]::GetFullPath((Join-Path $workingDirectory $executable))
        if (-not (Test-Path -LiteralPath $executableCandidate -PathType Leaf)) { Fail "AgentLocalCI relative executable is missing" 200 }
        $executable = Resolve-CanonicalPath $executableCandidate 'relative executable'
        if (-not (Is-Contained $executable $canonicalRepo)) { Fail "AgentLocalCI relative executable escaped the exact tree through a symbolic link" 200 }
    }
}

if ($needs -contains 'gradle' -and [IO.Path]::GetFileName($executable) -ceq 'gradlew') {
    foreach ($argument in $arguments) {
        if ($argument -match '^(--refresh-dependencies|--max-workers(?:=|$)|-Dorg\.gradle\.workers\.max(?:=|$))') { Fail "AgentLocalCI owns Gradle offline and worker policy" 200 }
    }
    if ($arguments -notcontains '--offline') { $arguments += '--offline' }
    if ($arguments -notcontains '--no-daemon') { $arguments += '--no-daemon' }
    if ($arguments -notcontains '--console=plain') { $arguments += '--console=plain' }
    $arguments += "--max-workers=$([int]$job.gradle_max_workers)"
}

$exitCode = Get-ExternalChildExitCode (Invoke-Child $executable $arguments $workingDirectory ([pscustomobject]$childEnvironment)
)
exit $exitCode

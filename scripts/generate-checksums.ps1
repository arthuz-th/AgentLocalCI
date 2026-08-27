[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\artifacts\SHA256SUMS")
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$base = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output = [IO.Path]::GetFullPath($OutputPath)
$files = [Collections.Generic.Dictionary[string, IO.FileInfo]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($candidate in $Path) {
    $resolved = [IO.Path]::GetFullPath($candidate)
    if (Test-Path -LiteralPath $resolved -PathType Leaf) { $files[$resolved] = Get-Item -LiteralPath $resolved }
    elseif (Test-Path -LiteralPath $resolved -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $resolved -Recurse -File)) { if ($file.FullName -cne $output) { $files[$file.FullName] = $file } }
    }
    else { throw "checksum input does not exist: $candidate" }
}
$lines = @($files.Values | Sort-Object FullName | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($base, $_.FullName).Replace([char]92, '/')
    "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $relative"
})
[IO.Directory]::CreateDirectory((Split-Path -Parent $output)) | Out-Null
[IO.File]::WriteAllLines($output, $lines, [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ Output = $output; FileCount = $lines.Count; Sha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant() }

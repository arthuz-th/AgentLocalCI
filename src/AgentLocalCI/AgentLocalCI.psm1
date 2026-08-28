Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

$script:AgentLocalCiModuleRoot = $PSScriptRoot
$script:AgentLocalCiVersion = "0.2.0-beta.1"
$script:AgentLocalCiSchemaVersion = 1
$script:AgentLocalCiOwnerLabel = "agentlocalci"
$script:AgentLocalCiBoundaryMarker = "unprivileged-linux-container"
$script:AgentLocalCiContainerUid = "10001:10001"
$script:AgentLocalCiPipelinePath = ".agentlocalci/pipeline.yml"

foreach ($privateFile in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "Private") -Filter "*.ps1" -File | Sort-Object Name)) {
    . $privateFile.FullName
}

Export-ModuleMember -Function Invoke-AgentLocalCiCli

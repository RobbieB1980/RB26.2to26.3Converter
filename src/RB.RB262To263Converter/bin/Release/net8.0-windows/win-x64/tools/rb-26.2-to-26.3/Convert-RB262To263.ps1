[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [string]$OutputPath = '',
    [string]$NeoVersion = 'neoforge-26.3.0.7-beta'
)
. (Join-Path $PSScriptRoot 'lib\Convert-RB262To263.ps1')
Invoke-RB262To263 -InputPath $InputPath -OutputPath $OutputPath -NeoVersion $NeoVersion | ConvertTo-Json -Depth 20

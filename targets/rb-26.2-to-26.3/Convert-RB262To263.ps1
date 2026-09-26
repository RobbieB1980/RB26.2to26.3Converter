[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [string]$OutputPath = '',
    [string]$NeoVersion = 'neoforge-26.3.0.7-beta',
    [string]$GeckoLibVersion = 'geckolib-neoforge-26.3-5.5.7',
    [switch]$OfflineDependencies
)
. (Join-Path $PSScriptRoot 'lib\Convert-RB262To263.ps1')
$result = Invoke-RB262To263 -InputPath $InputPath -OutputPath $OutputPath -NeoVersion $NeoVersion -GeckoLibVersion $GeckoLibVersion -OfflineDependencies:$OfflineDependencies
$result | ConvertTo-Json -Depth 20
if ($result.status -eq 'NeedsDependencyRepair') { exit 3 }

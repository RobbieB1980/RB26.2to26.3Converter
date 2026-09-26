[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [string]$CacheRoot = 'C:\GokuCodexAI\Data\Mod_Dependencies',
    [string]$GeckoLibVersion = 'geckolib-neoforge-26.3-5.5.7',
    [switch]$Offline
)
$ErrorActionPreference='Stop'
$argsList=@('-3.14','-X','utf8',(Join-Path $PSScriptRoot 'dependencies.py'),'--source',$SourcePath,'--project',$ProjectRoot,'--cache',$CacheRoot,'--gecko',$GeckoLibVersion)
if($Offline){$argsList+='--offline'}
& py.exe @argsList
exit $LASTEXITCODE

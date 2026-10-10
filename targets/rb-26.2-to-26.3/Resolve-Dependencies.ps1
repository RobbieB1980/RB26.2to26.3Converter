[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [string]$CacheRoot = 'C:\GokuCodexAI\Data\Mod_Dependencies',
    [string]$GeckoLibVersion = 'geckolib-neoforge-26.3-5.5.7',
    [switch]$Offline
)
$ErrorActionPreference='Stop'
$python = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($python) {
    $versionText = & $python.Source --version 2>&1 | Out-String
    if ($versionText -notmatch 'Python\s+3\.(1[1-9]|[2-9]\d)(?:\.|\s)') { $python = $null }
}
if (-not $python) {
    $launcher = Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $launcher) { throw 'Python 3.11 or newer is required for exact-target dependency resolution.' }
    $argsList=@('-3','-X','utf8',(Join-Path $PSScriptRoot 'dependencies.py'),'--source',$SourcePath,'--project',$ProjectRoot,'--cache',$CacheRoot,'--gecko',$GeckoLibVersion)
    if($Offline){$argsList+='--offline'}
    & $launcher.Source @argsList
    exit $LASTEXITCODE
}
$argsList=@('-X','utf8',(Join-Path $PSScriptRoot 'dependencies.py'),'--source',$SourcePath,'--project',$ProjectRoot,'--cache',$CacheRoot,'--gecko',$GeckoLibVersion)
if($Offline){$argsList+='--offline'}
& $python.Source @argsList
exit $LASTEXITCODE

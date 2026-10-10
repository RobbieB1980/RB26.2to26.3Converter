[CmdletBinding()]
param([string]$TargetRoot)
$ErrorActionPreference = 'Stop'
if (-not $TargetRoot) { $TargetRoot = Join-Path $PSScriptRoot '../targets/rb-26.2-to-26.3' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('rb-codex-discovery-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $root 'project'
$local = Join-Path $root 'Local App Data'
$desktopBin = Join-Path $local 'OpenAI/Codex/bin/test-version'
New-Item -ItemType Directory -Path $project,$desktopBin,(Join-Path $root 'config') -Force | Out-Null
'{"codex_orchestrator":{"primary":{"model":"test","reasoning_effort":"high"},"fallback":{"model":"fallback","reasoning_effort":"medium"}}}' | Set-Content (Join-Path $root 'config/gokuai.json')
'{"target_id":"rb-26.2-to-26.3","source_minecraft":"26.2","target_minecraft":"26.3","target_neo_version":"neoforge-26.3.0.22-beta"}' | Set-Content (Join-Path $project 'conversion-manifest.json')
$expected = Join-Path $desktopBin 'codex.exe'
[IO.File]::WriteAllText($expected, 'test executable: launch is intercepted')
$savedPath = $env:PATH
$savedLocal = $env:LOCALAPPDATA
$savedRoaming = $env:APPDATA
$capture = @{ launch = $null }
# Intercept only the interactive process boundary; execute the actual launcher.
function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory)
    $capture.launch = [pscustomobject]@{ FilePath=$FilePath; Arguments=$ArgumentList; Directory=$WorkingDirectory }
}
try {
    $env:PATH = Join-Path $root 'empty-path'
    $env:LOCALAPPDATA = $local
    $env:APPDATA = Join-Path $root 'Roaming'
    $capture.launch = $null
    & "$TargetRoot/Open-CodexRepairSession.ps1" -FailedOutput $project -GokuRoot $root
    if (-not $capture.launch) { throw 'Installed desktop CLI was not launched when absent from PATH.' }
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($capture.launch.Arguments[-1]))
    if (-not $decoded.StartsWith("& '$expected' ")) { throw "Wrong CLI selected: $decoded" }
    if ($capture.launch.Directory -ne $project) { throw 'Repair launched in wrong project.' }
    if (-not $decoded.Contains("'-m' 'gpt-6-luna'") -or -not $decoded.Contains("'model_reasoning_effort=`"medium`"'")) { throw 'Repair model or medium reasoning effort was not selected.' }
    $capture.launch = $null
    $rejected = $false
    try {
        & "$TargetRoot/Open-CodexRepairSession.ps1" -FailedOutput $project -GokuRoot $root -CodexPath (Join-Path $root 'missing.exe')
    } catch { $rejected = $_.Exception.Message -match 'Specified Codex CLI does not exist' }
    if (-not $rejected -or $capture.launch) { throw 'Invalid explicit CLI path must fail before launching.' }
    $env:LOCALAPPDATA = Join-Path $root 'missing-local'
    & "$TargetRoot/Open-CodexRepairSession.ps1" -FailedOutput $project -GokuRoot $root -PrepareOnly
    $rejected = $false
    try { & "$TargetRoot/Open-CodexRepairSession.ps1" -FailedOutput $project -GokuRoot $root }
    catch { $rejected = $_.Exception.Message -match 'Prepared request is retained at' }
    if (-not $rejected) { throw 'Missing CLI did not preserve an actionable repair packet.' }
    Write-Host "PASS: desktop discovery without PATH, project/route preservation, invalid explicit path, PrepareOnly, missing CLI. Fixture: $root"
} finally {
    $env:PATH = $savedPath
    $env:LOCALAPPDATA = $savedLocal
    $env:APPDATA = $savedRoaming
}

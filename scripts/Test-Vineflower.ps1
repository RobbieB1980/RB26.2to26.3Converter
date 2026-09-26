$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$lib=Join-Path $repo 'targets/rb-26.2-to-26.3/legacy-pipeline/lib'
. (Join-Path $lib 'VineflowerRuntime.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('rb-vineflower-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$good=Join-Path $lib 'decompiler-cache/vineflower-1.12.0.jar'
$script:requests=0
function Invoke-WebRequest { param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec)
    $script:requests++
    if($script:requests -eq 1){throw 'Simulated DNS failure'}
    Copy-Item -LiteralPath $good -Destination $OutFile
}
$actual=Get-VineflowerJar -Version '1.12.0' -CacheDir $fixture
if($script:requests -ne 2){throw 'Fallback was not exercised'}
Get-VineflowerJar -Version '1.12.0' -CacheDir $fixture | Out-Null
if($script:requests -ne 2){throw 'Valid cache attempted networking'}
[IO.File]::WriteAllText($actual,'broken')
function Invoke-WebRequest { param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec) [IO.File]::WriteAllText($OutFile,'corrupt download') }
$rejected=$false
try { Get-VineflowerJar -Version '1.12.0' -CacheDir $fixture | Out-Null } catch {$rejected=$true}
if(-not $rejected){throw 'Corrupt JAR accepted'}
if(Get-ChildItem $fixture -Filter '*.part'){throw 'Partial downloads left behind'}
Write-Host 'PASS: mirror fallback, verified offline cache, corrupt cache/download rejection, partial cleanup.'

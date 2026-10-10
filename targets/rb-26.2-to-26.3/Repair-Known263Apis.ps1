[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectRoot,[Parameter(Mandatory)][string]$NeoVersion)
$ErrorActionPreference='Stop'
if (($NeoVersion -replace '^neoforge-','') -ne '26.3.0.22-beta') { throw 'Known API rules require exact NeoForge 26.3.0.22-beta.' }
$ast=Join-Path $PSScriptRoot 'lib/ast'
$parser=Join-Path $ast 'javaparser-core-3.28.2.jar'
if (!(Test-Path $parser) -or (Get-FileHash $parser).Hash -ne 'B5499A3B1C40B16C0671FABE478C9AAFEAB38160C6FDE74A6C13F42D86716ECD') { throw 'Pinned JavaParser runtime is missing or corrupt.' }
$javaHome=Get-ChildItem (Join-Path ${env:ProgramFiles} 'Eclipse Adoptium') -Directory -Filter 'jdk-25*' | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
if (!$javaHome) { throw 'Java 25 is required for known API repair.' }
& (Join-Path $javaHome 'bin/java.exe') --class-path $parser (Join-Path $ast 'Known263Apis.java') $ProjectRoot
if ($LASTEXITCODE -ne 0) { throw "Known API repair failed: $LASTEXITCODE" }

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$desktop = [Environment]::GetFolderPath('Desktop')
$portable = Join-Path $desktop 'RB-26.2-to-26.3-Converter'
if (Test-Path $portable) { Remove-Item $portable -Recurse -Force }
$staging = Join-Path $repo 'dist\desktop-staging'
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging | Out-Null
tar.exe -xf (Join-Path $repo 'dist\RB-26.2-to-26.3-Converter-Portable.zip') -C $staging
$root = Join-Path $staging 'RB-26.2-to-26.3-Converter'
Move-Item $root $portable
Write-Host (Join-Path $portable 'RB-26.2-to-26.3-Converter.exe')
Write-Host (Join-Path $portable 'tools\rb-26.2-to-26.3\Convert-RB262To263.ps1')

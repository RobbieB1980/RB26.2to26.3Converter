[CmdletBinding()]
param(
    [ValidateSet('Release','Debug')][string]$Configuration = 'Release',
    [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Dist = Join-Path $Repo 'dist'
$Payload = Join-Path $Dist 'payload\RB-26.2-to-26.3-Converter'
$AppProject = Join-Path $Repo 'src\RB.RB262To263Converter\RB.RB262To263Converter.csproj'
$SetupProject = Join-Path $Repo 'src\RB.RB262To263Converter.Setup\RB.RB262To263Converter.Setup.csproj'

if (Test-Path $Dist) { Remove-Item $Dist -Recurse -Force }
New-Item -ItemType Directory -Path $Payload -Force | Out-Null

Write-Host 'Publishing converter...' -ForegroundColor Cyan
dotnet publish $AppProject -c $Configuration -r $Runtime --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false -o $Payload
if ($LASTEXITCODE -ne 0) { throw 'Converter publish failed.' }

Copy-Item (Join-Path $Repo 'targets\rb-26.2-to-26.3\README.md') $Payload -Force
Copy-Item (Join-Path $Repo 'targets\rb-26.2-to-26.3\target-manifest.json') $Payload -Force
Copy-Item (Join-Path $Repo 'targets\rb-26.2-to-26.3\CHANGELOG.md') $Payload -Force
if (Test-Path (Join-Path $Repo 'LICENSE')) { Copy-Item (Join-Path $Repo 'LICENSE') $Payload -Force }
if (Test-Path (Join-Path $Repo 'assets\app.ico')) { Copy-Item (Join-Path $Repo 'assets\app.ico') $Payload -Force }

$zip = Join-Path $Dist 'portable-payload.zip'
tar.exe -a -c -f $zip -C (Join-Path $Dist 'payload') 'RB-26.2-to-26.3-Converter'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zip)) { throw 'Payload archive failed.' }

Write-Host 'Publishing installer...' -ForegroundColor Cyan
$setupOut = Join-Path $Dist 'setup'
dotnet publish $SetupProject -c $Configuration -r $Runtime --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false -o $setupOut
if ($LASTEXITCODE -ne 0) { throw 'Installer publish failed.' }
$installer = Join-Path $setupOut 'RB-26.2-to-26.3-Converter-Setup.exe'
if (-not (Test-Path $installer)) { throw "Installer missing: $installer" }
Copy-Item $installer (Join-Path $Dist 'RB-26.2-to-26.3-Converter-Setup.exe') -Force

$portableZip = Join-Path $Dist 'RB-26.2-to-26.3-Converter-Portable.zip'
tar.exe -a -c -f $portableZip -C (Join-Path $Dist 'payload') 'RB-26.2-to-26.3-Converter'
if ($LASTEXITCODE -ne 0) { throw 'Portable archive failed.' }

$exe = Join-Path $Payload 'RB-26.2-to-26.3-Converter.exe'
if (-not (Test-Path $exe)) { throw 'Published converter executable missing.' }
Write-Host "Installer: $installer" -ForegroundColor Green
Write-Host "Portable: $portableZip" -ForegroundColor Green

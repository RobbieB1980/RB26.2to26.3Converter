$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\targets\rb-26.2-to-26.3\lib\Convert-RB262To263.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('rb-encoding-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$path = Join-Path $fixture 'Example.java'
$source = 'class Example { void test() { player.swing(InteractionHand.MAIN_HAND); } } // ' + [char]0x00E9
[IO.File]::WriteAllText($path, $source, [Text.UTF8Encoding]::new($true))
Normalize-JavaSources $fixture | Out-Null
if ((Update-Java26x3Apis $fixture) -ne 1) { throw 'Expected an API rewrite' }
$bytes = [IO.File]::ReadAllBytes($path)
if ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'API rewrite reintroduced BOM' }
if (-not [IO.File]::ReadAllText($path).EndsWith([string][char]0x00E9)) { throw 'UTF-8 content was corrupted' }
$before = (Get-FileHash -LiteralPath $path).Hash
if ((Update-Java26x3Apis $fixture) -ne 0) { throw 'Rewrite is not idempotent' }
if ((Get-FileHash -LiteralPath $path).Hash -ne $before) { throw 'Second pass changed bytes' }
Write-Output "PASS: BOM-free API rewrite, Unicode preservation, idempotence (PowerShell $($PSVersionTable.PSVersion))"

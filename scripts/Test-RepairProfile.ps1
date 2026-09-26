$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot '../targets/rb-26.2-to-26.3'
$root = Join-Path ([IO.Path]::GetTempPath()) ('rb-repair-test-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $root 'project'
New-Item -ItemType Directory -Path $project,(Join-Path $root 'config') -Force | Out-Null
'{"codex_orchestrator":{"primary":{"model":"test","reasoning_effort":"high"},"fallback":{"model":"test","reasoning_effort":"medium"}}}' | Set-Content (Join-Path $root 'config/gokuai.json')
$manifest = @{target_id='rb-26.2-to-26.3';source_minecraft='26.2';target_minecraft='26.3';target_neo_version='neoforge-26.3.0.7-beta'}
$manifest | ConvertTo-Json | Set-Content (Join-Path $project 'conversion-manifest.json')
"error: illegal character: '\ufeff'" | Set-Content (Join-Path $project 'compile-errors.log')
& "$target/Open-CodexRepairSession.ps1" -FailedOutput $project -GokuRoot $root -PrepareOnly
$packet = Get-ChildItem "$project/.gokuai/issues" -Directory | Select-Object -First 1
$request = Get-Content "$($packet.FullName)/request.json" -Raw | ConvertFrom-Json
if (@($request.matched_cases).Count -ne 1) { throw 'Expected exact BOM case.' }
if (-not (Test-Path $request.official_primer)) { throw 'Bundled primer fallback missing.' }
if (-not ($request.evidence_paths | Where-Object { $_.EndsWith('build-toolchain.md') })) { throw 'Toolchain evidence missing.' }
& "$target/Save-ConversionCase.ps1" -ProjectRoot $project -GokuRoot $root -ExitCode 1
if (Test-Path "$project/.gokuai/solved-cases") { throw 'Failed build was promoted.' }
$manifest.target_minecraft='26.2'
$manifest | ConvertTo-Json | Set-Content (Join-Path $project 'conversion-manifest.json')
$rejected=$false
try { & "$target/Open-CodexRepairSession.ps1" -FailedOutput $project -GokuRoot $root -PrepareOnly } catch { $rejected=$true }
if (-not $rejected) { throw 'Legacy target was accepted.' }
Write-Host "PASS: exact case, bundled primer, toolchain evidence, failed build guard, legacy target rejection. Fixture: $root"

$ErrorActionPreference='Stop'
$target=Join-Path $PSScriptRoot '../targets/rb-26.2-to-26.3'
$root=Join-Path $env:TEMP ('rb-retention-'+[guid]::NewGuid().ToString('N'))
$project="$root/project"
New-Item -ItemType Directory -Path "$project/src/main/java","$project/.gokuai","$root/config" -Force | Out-Null
'{"codex_orchestrator":{"primary":{"model":"test","reasoning_effort":"high"},"fallback":{"model":"test","reasoning_effort":"medium"}}}' | Set-Content "$root/config/gokuai.json"
'{"target_id":"rb-26.2-to-26.3","source_minecraft":"26.2","target_minecraft":"26.3","target_neo_version":"neoforge-26.3.0.22-beta"}' | Set-Content "$project/conversion-manifest.json"
'class Sample {}' | Set-Content "$project/src/main/java/Sample.java"
'CHANGED src/main/java/Sample.java : fixture' | Set-Content "$project/.gokuai/known-263-api-repair.txt"
'& bogus' | Set-Content "$project/compile-errors.log"
& "$target/Save-ConversionCase.ps1" -ProjectRoot $project -GokuRoot $root -ExitCode 1
if(Test-Path "$project/.gokuai/solved-cases"){throw 'Failed build promoted'}
'BUILD SUCCESSFUL' | Set-Content "$project/compile-errors.log"
& "$target/Save-ConversionCase.ps1" -ProjectRoot $project -GokuRoot $root -ExitCode 0 -Tasks 'fixture-build'
$case=Get-ChildItem "$project/.gokuai/solved-cases" -Directory | Select-Object -First 1
if(!(Test-Path "$($case.FullName)/source-fingerprints.json")){throw 'Source fingerprints missing'}
if(!(Test-Path "$($case.FullName)/.gokuai/known-263-api-repair.txt")){throw 'Applied rules missing'}
$record=Get-Content "$($case.FullName)/case.json" -Raw | ConvertFrom-Json
if($record.automatic_patch_eligible -or $record.runtime -ne 'not-tested'){throw 'Build inferred promotion/runtime'}
& "$target/Open-CodexRepairSession.ps1" -FailedOutput $project -GokuRoot $root -PrepareOnly
$packet=Get-ChildItem "$project/.gokuai/issues" -Directory | Select-Object -First 1
$request=Get-Content "$($packet.FullName)/request.json" -Raw | ConvertFrom-Json
if(@($request.prior_build_cases).Count -ne 1){throw 'Repair did not retrieve prior build'}
Write-Host 'PASS: failed-build guard, source fingerprints, applied rules, conservative promotion, repair history.'

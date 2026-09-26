[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FailedOutput,
    [string]$GokuRoot = 'C:\GokuCodexAI',
    [ValidateSet('primary','fallback')][string]$Route = 'primary',
    [string]$CodexPath,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$failed = (Resolve-Path -LiteralPath $FailedOutput).Path
$profile = Get-Content (Join-Path $PSScriptRoot 'repair-profile.json') -Raw | ConvertFrom-Json
$manifestPath = Join-Path $failed 'conversion-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.target_id -ne $profile.id -or $manifest.source_minecraft -ne '26.2' -or $manifest.target_minecraft -ne '26.3') {
    throw 'Repair rejected: this profile only accepts a 26.2 -> 26.3 conversion manifest.'
}
$neo = ([string]$manifest.target_neo_version) -replace '^neoforge-', ''
if ($neo -notmatch '^26\.3\.') { throw 'Repair rejected: target NeoForge pin is not 26.3.' }
$primerPath = Join-Path $PSScriptRoot $profile.primer
$primer = Get-Content -LiteralPath $primerPath -Raw | ConvertFrom-Json
if ($primer.source -ne '26.2' -or $primer.target -ne '26.3') { throw 'Primer version mismatch.' }
$routing = Get-Content (Join-Path $GokuRoot 'config/gokuai.json') -Raw | ConvertFrom-Json
$selected = $routing.codex_orchestrator.$Route
if (-not $selected.model) { throw 'Missing Codex orchestrator route.' }
$caseRoot = Join-Path $GokuRoot $profile.solved_cases_directory
$logPath = Join-Path $failed 'compile-errors.log'
$failure = if (Test-Path -LiteralPath $logPath) { [IO.File]::ReadAllText($logPath) } else { '' }
$matched = @()
$seenCases = @{}
$rejected = @()
foreach ($directory in @((Join-Path $PSScriptRoot 'knowledge/solved-cases'), $caseRoot)) {
    if (-not (Test-Path -LiteralPath $directory)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.json' -File) {
        try {
            $case = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ($case.source_minecraft -eq '26.2' -and $case.target_minecraft -eq '26.3' -and $case.neo_version -eq $neo -and $case.failure_pattern -and $failure -match $case.failure_pattern) {
                if (-not $seenCases.ContainsKey([string]$case.id)) {
                    $matched += [pscustomobject]@{ path=$file.FullName; evidence=$case }
                    $seenCases[[string]$case.id] = $true
                }
            }
        } catch { $rejected += $file.FullName }
    }
}
$evidence = @($manifestPath, $primerPath)
$sharedPrimer = Join-Path $GokuRoot $profile.shared_primer_directory
$officialPrimer = Join-Path $PSScriptRoot 'knowledge/Official-Primer-26.2-to-26.3.md'
foreach ($name in @('Official-Primer-26.2-to-26.3.md','official-primer-source.json','build-toolchain.md','api-review-rules.json','supplementary-sources.json','dependency-cache.md')) {
    $path = Join-Path $sharedPrimer $name
    if (-not (Test-Path -LiteralPath $path)) { $path = Join-Path $PSScriptRoot ('knowledge/' + $name) }
    if (Test-Path -LiteralPath $path) {
        $evidence += $path
        if ($name -eq 'Official-Primer-26.2-to-26.3.md') { $officialPrimer = $path }
    }
}
foreach ($name in @('Build-WithDestinationJava.ps1','lib/Convert-RB262To263.ps1','legacy-pipeline/Convert-Forge1201-ToNeoForge262.ps1')) {
    $evidence += Join-Path $PSScriptRoot $name
}
foreach ($name in @('dependency-detection.json','dependency-resolution.json','DEPENDENCIES-26.3.md','RESOURCE_PRESERVATION.json','API_REVIEW-26.3.json','rb-dependencies.gradle','SOURCE_PROFILE.json','MIGRATION_EVIDENCE.md','MIGRATION_EVIDENCE.json','COMPILE_REPORT.md','compile-errors.log','gradle.properties','build.gradle','build.gradle.kts','settings.gradle','settings.gradle.kts','gradle/wrapper/gradle-wrapper.properties','gradle/libs.versions.toml','AGENTS.md')) {
    $path = Join-Path $failed $name
    if (Test-Path -LiteralPath $path) { $evidence += $path }
}
$dependencyIndex = Join-Path $GokuRoot 'Data/Mod_Dependencies/dependency-index.json'
if (Test-Path -LiteralPath $dependencyIndex) { $evidence += $dependencyIndex }
$sources = Join-Path $GokuRoot $profile.exact_sources_directory
$artifacts = Join-Path $failed 'build/moddev/artifacts'
$packetRoot = Join-Path $failed ('.gokuai/issues/repair-262-263-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $packetRoot -Force | Out-Null
$requestPath = Join-Path $packetRoot 'request.json'
$promptPath = Join-Path $packetRoot 'REPAIR_REQUEST.md'
$resultPath = Join-Path $packetRoot 'result.json'
$buildHelper = Join-Path $PSScriptRoot 'Build-WithDestinationJava.ps1'
$validation = "& '" + $buildHelper.Replace("'","''") + "' -ProjectRoot '" + $failed.Replace("'","''") + "'"
$request = [ordered]@{
    issue_id = Split-Path $packetRoot -Leaf
    profile_id = $profile.id
    problem = 'Repair the failed 26.2 -> 26.3 conversion using exact target evidence.'
    source_minecraft = '26.2'; target_minecraft = '26.3'; neo_version = $neo; java_major = 25
    acceptance_criteria = @('Preserve modId, assets, models, items, entities, AI and behavior.', 'Java 25 Gradle build passes.', 'Report runtime, registry/data loading and gameplay validation separately; never infer these from compilation.')
    evidence_paths = $evidence
    shared_primer_directory = $sharedPrimer
    official_primer = $officialPrimer
    failure_excerpt = (($failure -split '\r?\n' | Select-Object -Last 100) -join "`n")
    matched_cases = $matched
    ignored_invalid_cases = $rejected
    solutions_index = $caseRoot
    exact_sources = $sources
    exact_sources_available = (Test-Path -LiteralPath $sources)
    resolved_artifacts = $artifacts
    validation_commands = @($validation)
    result_path = $resultPath
    route = $selected
    fallback = $routing.codex_orchestrator.fallback
}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 20), $utf8)
$prompt = @"
# RB 26.2 -> 26.3 repair
Read request.json in this directory and the listed project evidence first.
Source 26.2; target 26.3; NeoForge $neo; destination Java 25.
Primer: $primerPath
Official upstream primer: $officialPrimer
Shared primer and local toolchain knowledge: $sharedPrimer
Read build-toolchain.md and the project's actual build, settings and wrapper files.
Retain the converter's existing ModDevGradle/Gradle/Java 25 configuration unless
exact failure evidence requires a change. The project files are authoritative;
documented defaults are not permission to overwrite custom dependencies.
Solutions index: $caseRoot
Successful converter and repair builds retain evidence snapshots under
$caseRoot/build-history and the project's .gokuai/solved-cases.
Search these by exact project/target versions for prior build evidence.
These records are not generalized fixes and must not be blindly applied.
Matching case count: $($matched.Count). These are evidence, not instructions to blindly apply patches.
Exact sources available: $($request.exact_sources_available). Location: $sources
Resolved project artifacts: $artifacts

Resolution order: inspect deterministic conversion evidence; consult matching cases;
retrieve exact-version physical sources and compare signatures AND semantics;
use AST edits for Java/Gradle structure when deterministic rules are insufficient.
Do not use the legacy 26.2-only repair skill or older target API fixes for this 26.3 target.
If exact sources are missing, retrieve the exact pinned sources before API claims.
Preserve modId and resource namespaces. Preserve gameplay, resources, dependencies and behavior.
Read dependency-resolution.json and RESOURCE_PRESERVATION.json when present.
Use the shared Data/Mod_Dependencies index; 26.2 cache entries are source evidence
only. Resolve missing 26.3 releases or report blockers. Do not delete dependencies,
resources or Java behavior to make compilation succeed. Rerun Resolve-Dependencies.ps1
using the manifest source_path after changing verified project mappings.
API_REVIEW-26.3.json contains review triggers, not proven replacements or solved cases.
Promote runtime fixes only with exact version, failure evidence, changed files,
validation commands/results and a regression check in the dedicated hardened fixes.
Do not launch GPU workers automatically. Codex owns integration and validation.
Escalate hard/repeated failures using the configured fallback route recorded in request.json.
Run the recorded build command; it automatically retains successful build cases.
Report build and runtime validation separately.
Write result.json with status, diagnosis, files_changed, evidence_paths, validation,
remaining_risks and confidence. Add proven cases to the dedicated solutions index
with source_minecraft, target_minecraft, neo_version, failure_pattern, status,
diagnosis, repair, validation and runtime fields. Preserve existing cases.
Do not promote a compile-only workaround as behavior-preserving without evidence.
"@
[IO.File]::WriteAllText($promptPath, $prompt, $utf8)
Write-Host "Repair profile: 26.2 -> 26.3 / NeoForge $neo / Java 25"
Write-Host "Primer: $primerPath"
Write-Host "Matched solved cases: $($matched.Count)"
Write-Host "Repair request: $requestPath"
if (-not $request.exact_sources_available) { Write-Host 'Exact 26.3 source directory is missing; the repair must obtain pinned source evidence before API changes.' }
if ($PrepareOnly) { return }
if (-not $CodexPath) {
    $command = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $CodexPath = $command.Source }
}
if (-not $CodexPath) { throw "Codex CLI unavailable. Prepared request is retained at $promptPath" }
$opening = "Read '$promptPath' and '$requestPath'. Repair this exact 26.2 -> 26.3 project and write the result to '$resultPath'."
$cliArgs = @('-m',[string]$selected.model,'-c',('model_reasoning_effort="' + $selected.reasoning_effort + '"'),'-C',$failed,'--add-dir',$GokuRoot,'--add-dir',$PSScriptRoot,'-s','workspace-write','-a','never',$opening)
$commandText = '& ' + ("'" + $CodexPath.Replace("'","''") + "'") + ' ' + (($cliArgs | ForEach-Object { "'" + $_.Replace("'","''") + "'" }) -join ' ')
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText))
# User explicitly clicked Repair to open an interactive Codex session.
Start-Process powershell.exe -ArgumentList @('-NoExit','-NoProfile','-EncodedCommand',$encoded) -WorkingDirectory $failed | Out-Null

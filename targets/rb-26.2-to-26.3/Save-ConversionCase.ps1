[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][int]$ExitCode,
    [string]$Tasks,
    [string]$LogFileName = 'compile-errors.log',
    [string]$GokuRoot = 'C:\GokuCodexAI'
)
$ErrorActionPreference = 'Stop'
if ($ExitCode -ne 0) { return }
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$manifestPath = Join-Path $ProjectRoot 'conversion-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { return }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.target_id -ne 'rb-26.2-to-26.3' -or $manifest.source_minecraft -ne '26.2' -or $manifest.target_minecraft -ne '26.3') { throw 'Case target mismatch.' }
$id = 'build-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmss') + '-' + [guid]::NewGuid().ToString('N')
$caseRoot = Join-Path $ProjectRoot ('.gokuai/solved-cases/' + $id)
New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
$evidence = @()
$extra = @('.gokuai/known-263-api-repair.txt')
foreach ($folder in @('.gokuai/issues','.gokuai/repairs')) {
    $path = Join-Path $ProjectRoot $folder
    if (Test-Path $path) {
        $extra += @(Get-ChildItem $path -Recurse -File | Where-Object { $_.Name -in @('result.json','repair-result.json','runtime-confirmation.json') } | ForEach-Object { $_.FullName.Substring($ProjectRoot.TrimEnd('\').Length + 1) })
    }
}
foreach ($name in $extra) {
    $source = Join-Path $ProjectRoot $name
    if (Test-Path $source -PathType Leaf) {
        $dest = Join-Path $caseRoot $name
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $dest
        $evidence += @{path=$name;sha256=(Get-FileHash $dest).Hash}
    }
}
$fingerprints = @()
$sourceRoot = Join-Path $ProjectRoot 'src'
if (Test-Path $sourceRoot) {
    $fingerprints = @(Get-ChildItem $sourceRoot -Recurse -File | ForEach-Object {
        @{path=$_.FullName.Substring($ProjectRoot.TrimEnd('\').Length+1);sha256=(Get-FileHash $_.FullName).Hash}
    })
}
[IO.File]::WriteAllText((Join-Path $caseRoot 'source-fingerprints.json'),(ConvertTo-Json -InputObject $fingerprints -Depth 5))
$evidence += @{path='source-fingerprints.json';sha256=(Get-FileHash (Join-Path $caseRoot 'source-fingerprints.json')).Hash}
foreach ($name in @('dependency-detection.json','dependency-resolution.json','RESOURCE_PRESERVATION.json','API_REVIEW-26.3.json','rb-dependencies.gradle','conversion-manifest.json','MIGRATION_EVIDENCE.md','MIGRATION_EVIDENCE.json','COMPILE_REPORT.md',$LogFileName,'gradle.properties','build.gradle','build.gradle.kts','settings.gradle','settings.gradle.kts','gradle/wrapper/gradle-wrapper.properties')) {
    $source = Join-Path $ProjectRoot $name
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        $dest = Join-Path $caseRoot $name
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $dest
        $evidence += @{path=$name;sha256=(Get-FileHash -LiteralPath $dest).Hash}
    }
}
$record = [ordered]@{
    id=$id; source_minecraft='26.2'; target_minecraft='26.3'
    neo_version=([string]$manifest.target_neo_version -replace '^neoforge-','')
    status='build-verified'; runtime='not-tested'; project_path=$ProjectRoot
    diagnosis='Successful converter or repair build; no generalized repair diagnosis inferred.'
    repair='See captured migration evidence and build configuration.'
    validation=@{exit_code=$ExitCode;tasks=$Tasks;utc=[datetime]::UtcNow.ToString('o')}
    evidence=$evidence; automatic_patch_eligible=$false
    promotion_status='evidence-retained-review-required'
    promotion_requirements=@('Exact target diagnosis and failure pattern','Preservation and regression checks','Reviewed guarded rule or manual guidance','Runtime confirmation tied to the tested artifact when available')
}
[IO.File]::WriteAllText((Join-Path $caseRoot 'case.json'),($record | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
Write-Host "Build-verified case retained: $caseRoot"
$shared = Join-Path $GokuRoot 'Data/Solved_Problems/rb-26.2-to-26.3/build-history'
try {
    New-Item -ItemType Directory -Path $shared -Force | Out-Null
    Copy-Item -LiteralPath $caseRoot -Destination $shared -Recurse
    Write-Host "Shared case retained: $(Join-Path $shared $id)"
} catch { Write-Warning "Shared case copy failed; project copy retained: $($_.Exception.Message)" }

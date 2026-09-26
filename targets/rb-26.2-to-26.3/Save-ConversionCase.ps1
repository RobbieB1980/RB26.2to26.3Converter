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
$manifestPath = Join-Path $ProjectRoot 'conversion-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { return }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.target_id -ne 'rb-26.2-to-26.3' -or $manifest.source_minecraft -ne '26.2' -or $manifest.target_minecraft -ne '26.3') { throw 'Case target mismatch.' }
$id = 'build-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmss') + '-' + [guid]::NewGuid().ToString('N')
$caseRoot = Join-Path $ProjectRoot ('.gokuai/solved-cases/' + $id)
New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
$evidence = @()
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
}
[IO.File]::WriteAllText((Join-Path $caseRoot 'case.json'),($record | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
Write-Host "Build-verified case retained: $caseRoot"
$shared = Join-Path $GokuRoot 'Data/Solved_Problems/rb-26.2-to-26.3/build-history'
try {
    New-Item -ItemType Directory -Path $shared -Force | Out-Null
    Copy-Item -LiteralPath $caseRoot -Destination $shared -Recurse
    Write-Host "Shared case retained: $(Join-Path $shared $id)"
} catch { Write-Warning "Shared case copy failed; project copy retained: $($_.Exception.Message)" }

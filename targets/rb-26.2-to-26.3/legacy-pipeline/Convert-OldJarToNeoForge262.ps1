<#
.SYNOPSIS
  Full pipeline: finished .jar - decompile - NeoForge 26.2 scaffold.

.DESCRIPTION
  1) Convert-JarToProject.ps1  (Vineflower decompile + src layout)
  2) Convert-Forge1201-ToNeoForge262.ps1  (Gradle 26.2 + rewrites)

.EXAMPLE
  .\Convert-OldJarToNeoForge262.ps1 -JarPath "D:\mods\old.jar" -OutputPath "D:\mods\old-26.2"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JarPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$DecompilePath = '',
    [string]$MinecraftVersion = '26.2',
    [string]$SourceVersion = '',
    [string]$NeoVersion = '26.2.0.72',
    [string]$GeckoLibVersion = '5.5.3',
    [int]$DependencyDepth = 0,
    [int]$MaxDependencyDepth = 2,
    [string]$VisitedModIds = '',
    [string[]]$DependencyJarDir = @(),
    [switch]$SkipDependencyConvert,
    [switch]$SkipDependencyDownload,
    [switch]$ConvertOptionalDependencies,
    [switch]$Compile,
    [switch]$KeepDecompile,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ToolRoot = $PSScriptRoot
$jarScript = Join-Path $ToolRoot 'Convert-JarToProject.ps1'
$convScript = Join-Path $ToolRoot 'Convert-Forge1201-ToNeoForge262.ps1'
if (-not (Test-Path $jarScript)) { throw "Missing $jarScript" }
if (-not (Test-Path $convScript)) { throw "Missing $convScript" }

$JarPath = (Resolve-Path -LiteralPath $JarPath).Path
if (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) $OutputPath
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

if (-not $DecompilePath) {
    $base = [IO.Path]::GetFileNameWithoutExtension($JarPath)
    $parent = Split-Path $OutputPath -Parent
    if (-not $parent) { $parent = Get-Location }
    $DecompilePath = Join-Path $parent ($base + '-decompiled')
}
if (-not [IO.Path]::IsPathRooted($DecompilePath)) {
    $DecompilePath = Join-Path (Get-Location) $DecompilePath
}
$DecompilePath = [IO.Path]::GetFullPath($DecompilePath)

Write-Host ''
Write-Host 'RB Old JAR - NeoForge 26.2 (full pipeline)' -ForegroundColor White
Write-Host "  Jar       : $JarPath"
Write-Host "  Decompile : $DecompilePath"
Write-Host "  Final 26.2: $OutputPath"

if ($DryRun) {
    Write-Host 'Dry run: would decompile then convert.' -ForegroundColor Yellow
    & $jarScript -JarPath $JarPath -OutputPath $DecompilePath -SourceVersion $SourceVersion -DryRun
    return
}

& $jarScript -JarPath $JarPath -OutputPath $DecompilePath -MinecraftVersion $MinecraftVersion -NeoVersion $NeoVersion -SourceVersion $SourceVersion

$cargs = @{
    Path             = $DecompilePath
    OutputPath       = $OutputPath
    MinecraftVersion = $MinecraftVersion
    NeoVersion       = $NeoVersion
    GeckoLibVersion  = $GeckoLibVersion
}
# Invoke converter in a child process so its "exit 0" / compile noise cannot
# surface as a NativeCommandError under $ErrorActionPreference = 'Stop'.
# Quote paths: Start-Process ArgumentList array splits on spaces otherwise.
$convArgLine = "-NoProfile -ExecutionPolicy Bypass -File `"$convScript`" -Path `"$DecompilePath`" -OutputPath `"$OutputPath`" -MinecraftVersion `"$MinecraftVersion`" -NeoVersion `"$NeoVersion`" -GeckoLibVersion `"$GeckoLibVersion`" -DependencyDepth $DependencyDepth -MaxDependencyDepth $MaxDependencyDepth -OriginalJarPath `"$JarPath`""
if ($SourceVersion) { $convArgLine += " -SourceVersion `"$SourceVersion`"" }
if ($VisitedModIds) { $convArgLine += " -VisitedModIds `"$VisitedModIds`"" }
if ($Compile) { $convArgLine += ' -Compile' }
if ($SkipDependencyConvert) { $convArgLine += ' -SkipDependencyConvert' }
if ($SkipDependencyDownload) { $convArgLine += ' -SkipDependencyDownload' }
if ($ConvertOptionalDependencies) { $convArgLine += ' -ConvertOptionalDependencies' }
foreach ($depDir in @($DependencyJarDir)) {
    if ($depDir) { $convArgLine += " -DependencyJarDir `"$depDir`"" }
}

$convProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $convArgLine -WorkingDirectory $ToolRoot -Wait -PassThru -NoNewWindow
$convCode = $convProc.ExitCode
if ($null -eq $convCode) { $convCode = 0 }

$scaffoldOk = (Test-Path (Join-Path $OutputPath 'LEGACY_MIGRATION_REPORT.md')) -or
              (Test-Path (Join-Path $OutputPath 'build.gradle'))
if (-not $scaffoldOk -and $convCode -ne 0) {
    throw "NeoForge 26.2 convert failed (exit $convCode) and no scaffold was written under $OutputPath"
}
if ($convCode -ne 0 -and $scaffoldOk) {
    Write-Host "Converter process exit $convCode but scaffold is present - treating as success." -ForegroundColor Yellow
}

if (-not $KeepDecompile) {
    Write-Host "==> Intermediate decompile kept at: $DecompilePath" -ForegroundColor Cyan
    Write-Host "    (pass -KeepDecompile is default keep; delete manually if desired)" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host "Pipeline complete." -ForegroundColor Green
Write-Host "  Decompiled project : $DecompilePath"
Write-Host "  NeoForge 26.2      : $OutputPath"
Write-Host ''
Write-Host 'Next: open the 26.2 project and run gradlew build. Install ONLY build/libs output.' -ForegroundColor Cyan
Write-Host 'Do NOT rename/copy the original input jar into a 26.2 mods folder.' -ForegroundColor Yellow
# A requested build is only complete when an installable jar exists.
if ($Compile) {
    $builtJars = @(Get-ChildItem -LiteralPath (Join-Path $OutputPath 'build\libs') -Filter '*.jar' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'sources|javadoc' })
    if ($builtJars.Count -eq 0) {
        Write-Warning 'Scaffold completed, but the requested Gradle build did not produce an installable JAR.'
        exit 2
    }
    Write-Host "Installable JAR: $($builtJars[0].FullName)" -ForegroundColor Green
}
exit 0

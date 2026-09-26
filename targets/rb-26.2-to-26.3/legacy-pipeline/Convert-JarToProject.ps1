<#
.SYNOPSIS
  Decompile a finished Minecraft mod .jar into a source project folder.

.DESCRIPTION
  Unpacks the jar, decompiles classes with Vineflower, and lays out:
    src/main/java/...
    src/main/resources/... (assets, data, pack.mcmeta, etc.)
    DECOMPILE_REPORT.md
    stub gradle.properties (so RB Legacy Converter can accept the folder)

  This is NOT decryption - jars are not encrypted. It is a decompiler + layout tool.
  Output is a starting point only; expect manual cleanup.

.EXAMPLE
  .\Convert-JarToProject.ps1 -JarPath "D:\mods\mymod-1.20.1.jar" -OutputPath "D:\mods\mymod-decompiled"

.EXAMPLE
  .\Convert-JarToProject.ps1 -JarPath ".\mymod.jar" -OutputPath ".\mymod-src" -ContinueToNeoForge262
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JarPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$VineflowerVersion = '1.12.0',
    [string]$JavaExe = '',
    [switch]$ContinueToNeoForge262,
    [switch]$CompileAfterConvert,
    [string]$NeoVersion = '26.2.0.72',
    [string]$MinecraftVersion = '26.2',
    [string]$SourceVersion = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ToolRoot = $PSScriptRoot
$depLib = Join-Path $ToolRoot 'lib\ModDependencyPipeline.ps1'
if (Test-Path -LiteralPath $depLib) { . $depLib }
. (Join-Path $ToolRoot 'lib\ConversionCore.ps1')

function Write-Step([string]$m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2([string]$m) { Write-Host "    WARN: $m" -ForegroundColor Yellow }
function Write-Info([string]$m) { Write-Host "    $m" }

# Java detection/selection helpers live in lib/ConversionCore.ps1
# (Get-JarRequiredJavaMajor / Resolve-Java / Get-ProjectRequiredJavaMajor / Invoke-GradleBuildWithRequiredJava).

function Get-VineflowerJar {
    param([string]$Version, [string]$CacheDir)
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $name = "vineflower-$Version.jar"
    $dest = Join-Path $CacheDir $name
    if (Test-Path -LiteralPath $dest) { return $dest }
    $url = "https://repo1.maven.org/maven2/org/vineflower/vineflower/$Version/vineflower-$Version.jar"
    Write-Info "Downloading Vineflower $Version ..."
    Write-Info $url
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } catch {
        throw "Failed to download Vineflower from Maven Central: $($_.Exception.Message)"
    }
    if (-not (Test-Path $dest) -or ((Get-Item $dest).Length -lt 10000)) {
        throw "Vineflower download looks invalid: $dest"
    }
    return $dest
}

function Get-ModHintsFromJarExtract {
    param([string]$ExtractDir)
    $hints = [ordered]@{
        mod_id         = 'unknownmod'
        mod_name       = 'Unknown Mod'
        mod_version    = '1.0.0'
        loader         = 'unknown'
        mc_hint        = ''
        has_mixins     = $false
        notes          = New-Object System.Collections.Generic.List[string]
        dependencies   = @()
    }

    $modsToml = Get-ChildItem -Path $ExtractDir -Recurse -Filter 'mods.toml' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'META-INF' } | Select-Object -First 1
    $neoforgeToml = Get-ChildItem -Path $ExtractDir -Recurse -Filter 'neoforge.mods.toml' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $fabric = Join-Path $ExtractDir 'fabric.mod.json'
    $mcmod = Join-Path $ExtractDir 'mcmod.info'
    $quilt = Join-Path $ExtractDir 'quilt.mod.json'

    if ($neoforgeToml) {
        $hints.loader = 'neoforge'
        $text = Get-Content $neoforgeToml.FullName -Raw -ErrorAction SilentlyContinue
        if ($text -match 'modId\s*=\s*"([^"]+)"') { $hints.mod_id = $matches[1] }
        if ($text -match '(?m)^\s*version\s*=\s*"([^"]+)"') { $hints.mod_version = $matches[1] }
        if ($text -match 'displayName\s*=\s*"([^"]+)"') { $hints.mod_name = $matches[1] }
        if ($text -match 'minecraftVersion\s*=\s*"([^"]+)"') { $hints.mc_hint = $matches[1] }
    }
    elseif ($modsToml) {
        $hints.loader = 'forge/neoforge'
        $text = Get-Content $modsToml.FullName -Raw -ErrorAction SilentlyContinue
        if ($text -match 'modId\s*=\s*"([^"]+)"') { $hints.mod_id = $matches[1] }
        if ($text -match '(?m)^\s*version\s*=\s*"([^"]+)"') { $hints.mod_version = $matches[1] }
        if ($text -match 'displayName\s*=\s*"([^"]+)"') { $hints.mod_name = $matches[1] }
    }
    elseif (Test-Path $fabric) {
        $hints.loader = 'fabric'
        try {
            $j = Get-Content $fabric -Raw | ConvertFrom-Json
            if ($j.id) { $hints.mod_id = [string]$j.id }
            if ($j.name) { $hints.mod_name = [string]$j.name }
            if ($j.version) { $hints.mod_version = [string]$j.version }
            if ($j.depends.minecraft) { $hints.mc_hint = [string]$j.depends.minecraft }
        } catch { $hints.notes.Add('fabric.mod.json parse failed') }
    }
    elseif (Test-Path $quilt) {
        $hints.loader = 'quilt'
        $hints.notes.Add('Quilt mod detected - Legacy Converter targets Forge/NeoForge sources.')
    }
    elseif (Test-Path $mcmod) {
        $hints.loader = 'forge-legacy'
        $hints.notes.Add('mcmod.info found (very old Forge).')
    }

    if (Get-ChildItem -Path $ExtractDir -Recurse -Filter '*mixins*.json' -ErrorAction SilentlyContinue) {
        $hints.has_mixins = $true
        $hints.notes.Add('Mixin configs present - decompiled mixins often need heavy manual repair.')
    }

    $tomlText = $null
    if ($neoforgeToml) { $tomlText = Get-Content $neoforgeToml.FullName -Raw -ErrorAction SilentlyContinue }
    elseif ($modsToml) { $tomlText = Get-Content $modsToml.FullName -Raw -ErrorAction SilentlyContinue }
    if ($tomlText -and (Get-Command Read-TomlDependencyBlocks -ErrorAction SilentlyContinue)) {
        $hints.dependencies = @(Read-TomlDependencyBlocks -Text $tomlText -SelfModId $hints.mod_id)
        if ($hints.dependencies.Count -gt 0) {
            $hints.notes.Add("Declared dependencies: " + (($hints.dependencies | ForEach-Object { $_.ModId }) -join ', '))
        }
    }

    # Prefer package root as mod id if still unknown
    if ($hints.mod_id -eq 'unknownmod') {
        $pkg = Get-ChildItem -Path $ExtractDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('META-INF', 'assets', 'data', 'pack.mcmeta') } |
            Select-Object -First 1
        if ($pkg) { $hints.mod_id = $pkg.Name.ToLowerInvariant() }
    }

    return $hints
}

function Get-ResourceInventory {
    param([string]$ResourcesDir)
    $files = @(Get-ChildItem -LiteralPath $ResourcesDir -Recurse -File -ErrorAction SilentlyContinue)
    $inv = [ordered]@{
        files       = $files.Count
        png         = @($files | Where-Object { $_.Extension -eq '.png' }).Count
        ogg         = @($files | Where-Object { $_.Extension -in '.ogg', '.mus' }).Count
        nbt         = @($files | Where-Object { $_.Extension -eq '.nbt' }).Count
        json        = @($files | Where-Object { $_.Extension -eq '.json' }).Count
        geo         = @($files | Where-Object { $_.FullName -match '\\geo\\|\\geckolib\\models\\' }).Count
        animations  = @($files | Where-Object { $_.FullName -match '\\animations\\' }).Count
        blockstates = @($files | Where-Object { $_.FullName -match '\\blockstates\\' }).Count
        models      = @($files | Where-Object { $_.FullName -match '\\models\\' }).Count
        lang        = @($files | Where-Object { $_.FullName -match '\\lang\\' }).Count
        data        = @($files | Where-Object { $_.FullName -match '\\data\\' }).Count
    }
    return $inv
}

function Copy-JarResources {
    <#
    .SYNOPSIS
      Copy every non-class file from the unpacked jar into src/main/resources.
      assets/, data/, geo, sounds, textures, pack.mcmeta, logo.png, mixins, ATs.
      Never copies .class (those are decompiled to java instead).
    #>
    param([string]$ExtractDir, [string]$ResourcesDir)
    New-Item -ItemType Directory -Force -Path $ResourcesDir | Out-Null
    $copied = 0
    $skipExt = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('.class', '.sf', '.rsa', '.dsa', '.ec'),
        [StringComparer]::OrdinalIgnoreCase
    )
    $files = @(Get-ChildItem -LiteralPath $ExtractDir -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        if ($skipExt.Contains($f.Extension)) { continue }
        $rel = $f.FullName.Substring($ExtractDir.Length).TrimStart('\', '/')
        if ($rel -match '(?i)^META-INF[/\\][^/\\]+\.(SF|RSA|DSA|EC)$') { continue }
        $dest = Join-Path $ResourcesDir $rel
        Copy-FileLongPath -Source $f.FullName -Destination $dest
        $copied++
    }
    return $copied
}

# -------------------- main --------------------
$JarPath = (Resolve-Path -LiteralPath $JarPath).Path
if (-not ($JarPath.ToLowerInvariant().EndsWith('.jar'))) {
    Write-Warn2 "Input does not end with .jar - continuing anyway."
}
if (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) $OutputPath
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

Write-Host ''
Write-Host 'RB Legacy JAR Decompiler - finished .jar -> source project' -ForegroundColor White
Write-Host "  Jar    : $JarPath"
Write-Host "  Output : $OutputPath"
Write-Host "  Engine : Vineflower $VineflowerVersion"

if ($DryRun) {
    Write-Host '  DryRun : yes' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Would: extract jar, decompile classes, write src/main/java + resources, DECOMPILE_REPORT.md' -ForegroundColor Cyan
    if ($ContinueToNeoForge262) { Write-Host 'Would then run Convert-Forge1201-ToNeoForge262.ps1 on the decompiled project' -ForegroundColor Cyan }
    return
}

if (Test-Path -LiteralPath $OutputPath) {
    $items = @(Get-ChildItem -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue)
    if ($items.Count -gt 0) { throw "Output folder not empty: $OutputPath" }
}
else {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$cacheDir = Join-Path $ToolRoot 'lib\decompiler-cache'
$vine = Get-VineflowerJar -Version $VineflowerVersion -CacheDir $cacheDir
Write-Ok "Vineflower: $vine"

$requiredJava = Get-JarRequiredJavaMajor -JarPath $vine -FallbackJavaMajor 17
Write-Info "Vineflower bytecode requires Java $requiredJava+"
$javaChoice = Resolve-Java -Preferred $JavaExe -MinimumMajor $requiredJava -ForTool "Vineflower $VineflowerVersion"
$java = [string]$javaChoice.Path
$javaMajor = [int]$javaChoice.Major
if ($javaMajor -eq $requiredJava) {
    Write-Ok "Java: $java (major $javaMajor; exact match for Vineflower)"
} else {
    Write-Ok "Java: $java (major $javaMajor; Vineflower needs $requiredJava+, closest installed higher JDK)"
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("rb-jar-decompile-" + [guid]::NewGuid().ToString('N'))
$extractDir = Join-Path $work 'extract'
$decompileDir = Join-Path $work 'decompiled'
New-Item -ItemType Directory -Force -Path $extractDir, $decompileDir | Out-Null

try {
    Write-Step 'Extracting jar'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($JarPath, $extractDir)
    Write-Ok "Extracted to temp work dir"

    $hints = Get-ModHintsFromJarExtract -ExtractDir $extractDir
    $sourceProfile = Get-SourceProfile -Root $extractDir -VersionOverride $SourceVersion
    if ($sourceProfile.Loader -eq 'unknown' -and $hints.loader -ne 'unknown') {
        $sourceProfile.Loader = $hints.loader
        $sourceProfile.Route = Get-MigrationRoute -SourceVersion $sourceProfile.SourceVersion -Loader $sourceProfile.Loader
        $sourceProfile.RecommendedPasses = @(Get-RecommendedMigrationPasses -Route $sourceProfile.Route)
    }
    if ($sourceProfile.SourceVersion -eq 'unknown' -and $hints.mc_hint) {
        $detectedVersion = ConvertTo-NormalizedMinecraftVersion $hints.mc_hint
        if ($detectedVersion) {
            $sourceProfile.SourceVersion = $detectedVersion
            $sourceProfile.Confidence = 'high'
            $sourceProfile.Route = Get-MigrationRoute -SourceVersion $detectedVersion -Loader $sourceProfile.Loader
            $sourceProfile.RecommendedPasses = @(Get-RecommendedMigrationPasses -Route $sourceProfile.Route)
        }
    }
    Write-Info "Detected loader=$($sourceProfile.Loader) source_mc=$($sourceProfile.SourceVersion) route=$($sourceProfile.Route) mod_id=$($hints.mod_id)"

    Write-Step 'Decompiling classes (Vineflower)'
    # Vineflower: java -jar vineflower.jar <source> <destination>
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $java
    $psi.Arguments = "-jar `"$vine`" -dgs=1 `"$JarPath`" `"$decompileDir`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($stdout) { $stdout -split "`n" | Select-Object -Last 20 | ForEach-Object { if ($_) { Write-Info $_ } } }
    if ($stderr) { $stderr -split "`n" | Select-Object -Last 15 | ForEach-Object { if ($_) { Write-Warn2 $_ } } }
    if ($proc.ExitCode -ne 0) {
        throw "Vineflower exited with code $($proc.ExitCode)"
    }
    Write-Ok 'Decompile finished'

    Write-Step 'Laying out Maven/Gradle source tree'
    $javaOut = Join-Path $OutputPath 'src\main\java'
    $resOut = Join-Path $OutputPath 'src\main\resources'
    New-Item -ItemType Directory -Force -Path $javaOut, $resOut | Out-Null

    # Vineflower may emit .java under decompileDir mirroring packages, or nested jar folder
    $javaFiles = @(Get-ChildItem $decompileDir -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue)
    if ($javaFiles.Count -eq 0) {
        # Sometimes outputs into a subfolder named after the jar
        $alt = Get-ChildItem $decompileDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($alt) {
            $javaFiles = @(Get-ChildItem $alt.FullName -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue)
            $decompileRoot = $alt.FullName
        } else {
            $decompileRoot = $decompileDir
        }
    } else {
        $decompileRoot = $decompileDir
    }

    if ($javaFiles.Count -eq 0) {
        throw "No .java files produced by decompiler. The jar may be empty or obfuscated beyond recovery."
    }

    # Copy entire decompile tree package structure into src/main/java
    # Prefer copying all non-resource paths
    foreach ($jf in $javaFiles) {
        $rel = $jf.FullName.Substring($decompileRoot.Length).TrimStart('\', '/')
        $dest = Join-Path $javaOut $rel
        Copy-FileLongPath -Source $jf.FullName -Destination $dest
    }
    Write-Ok "Java sources: $($javaFiles.Count) files"

    $resCount = Copy-JarResources -ExtractDir $extractDir -ResourcesDir $resOut
    $inv = Get-ResourceInventory -ResourcesDir $resOut
    Write-Ok ("Resources copied: {0} files (png={1} ogg={2} geo={3} animations={4} models={5} blockstates={6} nbt={7} data={8})" -f `
        $inv.files, $inv.png, $inv.ogg, $inv.geo, $inv.animations, $inv.models, $inv.blockstates, $inv.nbt, $inv.data)
    if ($inv.png -eq 0 -and $inv.ogg -eq 0) {
        Write-Warn2 'Jar extract produced no textures or sounds. The 26.2 jar will be purple/black unless assets are restored later.'
    }
    Set-Content -Path (Join-Path $OutputPath 'original-jar.txt') -Value $JarPath -Encoding UTF8
    Write-SourceProfile -Profile $sourceProfile -Path (Join-Path $OutputPath 'SOURCE_PROFILE.json')

    # Stub project markers for converter + IDEs
    $jarName = [IO.Path]::GetFileName($JarPath)
    $propsLines = @(
        '# Generated by Convert-JarToProject.ps1 (decompiled jar - not original source)'
        "mod_id=$($hints.mod_id)"
        "mod_name=$($hints.mod_name)"
        "mod_version=$($hints.mod_version)"
        "mod_group_id=com.example.$($hints.mod_id)"
        'mod_authors=Unknown'
        "mod_description=Decompiled from $jarName. Requires manual cleanup."
        "source_minecraft_version=$($sourceProfile.SourceVersion)"
        "minecraft_version=$MinecraftVersion"
        "neo_version=$NeoVersion"
        'org.gradle.jvmargs=-Xmx2G'
    )
    Set-Content -Path (Join-Path $OutputPath 'gradle.properties') -Value ($propsLines -join [Environment]::NewLine) -Encoding UTF8

    $readmeLines = @(
        "# Decompiled project: $($hints.mod_name)"
        ""
        "Source jar: $JarPath"
        "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        ""
        "This folder was produced by Convert-JarToProject.ps1 (Vineflower)."
        "It is NOT original source code. Use RB Legacy Java Converter for NeoForge 26.2 scaffolding."
        ""
        "## Next step"
        ""
        "Convert-Forge1201-ToNeoForge262.ps1 -Path `"$OutputPath`" -OutputPath `"<empty-26.2-folder>`" -Compile"
    )
    Set-Content -Path (Join-Path $OutputPath 'README-DECOMPILED.md') -Value ($readmeLines -join [Environment]::NewLine) -Encoding UTF8

    $noteLines = @($hints.notes | ForEach-Object { "- $_" })
    if ($noteLines.Count -eq 0) { $noteLines = @('- (none)') }
    $reportLines = @(
        "# Decompile report"
        ""
        "- Jar: $JarPath"
        "- Output: $OutputPath"
        "- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        "- Vineflower: $VineflowerVersion"
        "- Java: $java"
        ""
        "## Detected metadata"
        ""
        "| Field | Value |"
        "|-------|-------|"
        "| Loader | $($hints.loader) |"
        "| mod_id | $($hints.mod_id) |"
        "| Name | $($hints.mod_name) |"
        "| Version | $($hints.mod_version) |"
        "| MC hint | $($hints.mc_hint) |"
        "| Detected source MC | $($sourceProfile.SourceVersion) |"
        "| Detection confidence | $($sourceProfile.Confidence) |"
        "| Migration route | $($sourceProfile.Route) |"
        "| Mixins | $($hints.has_mixins) |"
        "| Java files | $($javaFiles.Count) |"
        "| Resource files | $($inv.files) |"
        "| PNG textures | $($inv.png) |"
        "| Sounds | $($inv.ogg) |"
        "| Geo models | $($inv.geo) |"
        "| Animations | $($inv.animations) |"
        "| Block/item models | $($inv.models) |"
        "| Blockstates | $($inv.blockstates) |"
        "| Structures (nbt) | $($inv.nbt) |"
        "| Declared deps | $(@($hints.dependencies).Count) |"
        ""
        "## Notes"
        ""
    ) + $noteLines + @(
        ""
        "## Pipeline"
        ""
        "1. Done: jar extract + decompile + src layout"
        "2. Optional: run Convert-Forge1201-ToNeoForge262.ps1 on this folder to scaffold NeoForge 26.2 (reads detected-dependencies.json, downloads official 26.2 artifacts, converts remaining required mods)"
        "3. Manual: fix decompile artifacts, mixins, datapacks, GeckoLib paths, remaining compile errors."
        ""
        "## Limits"
        ""
        "- Decompiled code is imperfect (generics, lambdas, switch, records)."
        "- Obfuscated jars may be unreadable."
        "- Fabric/Quilt jars are extracted but the Legacy Converter targets Forge/NeoForge APIs."
        "- Original jar is never modified."
    )
    Set-Content -Path (Join-Path $OutputPath 'DECOMPILE_REPORT.md') -Value ($reportLines -join [Environment]::NewLine) -Encoding UTF8
    Write-Ok "Wrote DECOMPILE_REPORT.md"

    if ($hints.dependencies -and (Get-Command Write-DetectedDependenciesJson -ErrorAction SilentlyContinue)) {
        Write-DetectedDependenciesJson -Path (Join-Path $OutputPath 'detected-dependencies.json') -Records $hints.dependencies
        Write-Ok "Wrote detected-dependencies.json ($($hints.dependencies.Count) entries)"
    }

    Write-Host ''
    Write-Host "Decompile complete: $OutputPath" -ForegroundColor Green
    Write-Host 'Original jar unchanged.' -ForegroundColor Green

    if ($ContinueToNeoForge262) {
        $converter = Join-Path $ToolRoot 'Convert-Forge1201-ToNeoForge262.ps1'
        if (-not (Test-Path $converter)) { throw "Missing converter: $converter" }
        $baseOut = $OutputPath.TrimEnd('\', '/')
        $neoOut = $baseOut + '-26.2'
        if (Test-Path -LiteralPath $neoOut) {
            $i = 2
            while (Test-Path -LiteralPath ($baseOut + '-26.2-' + $i)) { $i++ }
            $neoOut = $baseOut + '-26.2-' + $i
        }
        Write-Step "Continuing to NeoForge 26.2 scaffold -> $neoOut"
        $cargs = @{
            Path             = $OutputPath
            OutputPath       = $neoOut
            MinecraftVersion = $MinecraftVersion
            NeoVersion       = $NeoVersion
            OriginalJarPath  = $JarPath
        }
        if ($CompileAfterConvert) { & $converter @cargs -Compile }
        else { & $converter @cargs }
        Write-Ok "NeoForge scaffold: $neoOut"
    }
}
finally {
    if (Test-Path $work) {
        try { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

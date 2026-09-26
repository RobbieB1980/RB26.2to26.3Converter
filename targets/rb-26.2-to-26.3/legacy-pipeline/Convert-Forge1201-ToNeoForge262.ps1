<#
.SYNOPSIS
  Experimental converter: Minecraft Forge 1.20.1 workspace -> NeoForge 26.2 scaffold.

.DESCRIPTION
  Copies the project, rewrites Gradle to ModDevGradle 26.2, maps known deps
  (GeckoLib, SmartBrainLib), applies mechanical Forge->NeoForge renames, and
  optionally runs compileJava to produce an error report.

  This is NOT a full automatic port. Expect many remaining compile errors on
  large mods. Goal of v1: runnable Gradle + modern deps + first-pass rewrites.

.EXAMPLE
  .\Convert-Forge1201-ToNeoForge262.ps1 -Path "F:\Grok Build Apps\Legacy\friend-main" -OutputPath "F:\Grok Build Apps\Friend-26.2" -Compile
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$MinecraftVersion = '26.2',
    [string]$NeoVersion = '26.2.0.72',
    [string]$ModDevGradleVersion = '2.0.144',
    [string]$GeckoLibVersion = '5.5.3',
    [string]$SmartBrainLibVersion = '2.0.0',
    [string]$LocalLibDir = '',
    [int]$DependencyDepth = 0,
    [int]$MaxDependencyDepth = 2,
    [string]$VisitedModIds = '',
    [string[]]$DependencyJarDir = @(),
    [switch]$SkipDependencyConvert,
    [switch]$SkipDependencyDownload,
    [switch]$ConvertOptionalDependencies,
    [switch]$Compile,
    [switch]$DryRun,
    [string]$OriginalJarPath = '',
    [string]$SourceVersion = ''
)

$ErrorActionPreference = 'Stop'
$ToolRoot = $PSScriptRoot
. (Join-Path $ToolRoot 'lib\ModDependencyPipeline.ps1')
. (Join-Path $ToolRoot 'lib\ConversionCore.ps1')
. (Join-Path $ToolRoot 'lib\Minecraft262HardenedTransforms.ps1')

function Write-Step([string]$m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2([string]$m) { Write-Host "    WARN: $m" -ForegroundColor Yellow }
function Write-Info([string]$m) { Write-Host "    $m" }

function Convert-DisplayClientMessageCalls {
    param([string]$Text)
    $needle = '.displayClientMessage('
    $guard = 0
    while ($guard -lt 50) {
        $i = $Text.IndexOf($needle)
        if ($i -lt 0) { break }
        $start = $i + $needle.Length
        $depth = 1
        $j = $start
        while ($j -lt $Text.Length -and $depth -gt 0) {
            $c = $Text[$j]
            if ($c -eq [char]'(') { $depth++ }
            elseif ($c -eq [char]')') { $depth-- }
            $j++
        }
        if ($depth -ne 0) { break }
        $args = $Text.Substring($start, $j - $start - 1)
        $args2 = [regex]::Replace($args, ',\s*(?:true|false)\s*$', '')
        $Text = $Text.Substring(0, $i) + '.sendSystemMessage(' + $args2 + ')' + $Text.Substring($j)
        $guard++
    }
    return $Text
}

function Copy-ProjectTree {
    param([string]$Source, [string]$Dest)
    $exclude = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('build', 'run', 'run-data', '.gradle', '.git', 'bin', 'out', '.idea', 'converted-deps', 'libs'),
        [StringComparer]::OrdinalIgnoreCase
    )
    if (Test-Path -LiteralPath $Dest) {
        $items = @(Get-ChildItem -LiteralPath $Dest -Force -ErrorAction SilentlyContinue)
        if ($items.Count -gt 0) { throw "Output folder not empty: $Dest" }
    }
    else {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    }
    $count = 0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Source)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $rel = if ($cur.Length -le $Source.Length) { '' } else { $cur.Substring($Source.Length).TrimStart('\', '/') }
        $destDir = if ($rel) { Join-Path $Dest $rel } else { $Dest }
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        foreach ($item in Get-ChildItem -LiteralPath $cur -Force -ErrorAction SilentlyContinue) {
            if ($item.PSIsContainer) {
                if ($exclude.Contains($item.Name)) { continue }
                $stack.Push($item.FullName)
            }
            else {
                Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $destDir $item.Name) -Force
                $count++
            }
        }
    }
    return $count
}

function Get-ModMetaFromSource {
    param([string]$Root)
    $meta = @{
        mod_id      = 'examplemod'
        mod_name    = 'Example Mod'
        mod_version = '1.0.0'
        mod_group   = 'com.example'
        mod_authors = 'Unknown'
        mod_license = 'All Rights Reserved'
        mod_desc    = 'Converted from Forge 1.20.1'
    }
    $folder = Split-Path $Root -Leaf
    $meta.mod_id = ($folder -replace '[^a-z0-9_]', '').ToLower()
    if ($meta.mod_id.Length -lt 2) { $meta.mod_id = 'friend' }

    $gp = Join-Path $Root 'gradle.properties'
    if (Test-Path $gp) {
        foreach ($line in Get-Content $gp) {
            if ($line -match '^\s*mod_version\s*=\s*(.+)$') { $meta.mod_version = $Matches[1].Trim() }
            if ($line -match '^\s*mod_id\s*=\s*(.+)$') { $meta.mod_id = $Matches[1].Trim() }
            if ($line -match '^\s*mod_name\s*=\s*(.+)$') { $meta.mod_name = $Matches[1].Trim() }
            if ($line -match '^\s*mod_authors\s*=\s*(.+)$') { $meta.mod_authors = $Matches[1].Trim() }
            if ($line -match '^\s*mod_license\s*=\s*(.+)$') { $meta.mod_license = $Matches[1].Trim() }
        }
    }
    # Prefer display metadata from existing NeoForge/Forge toml (jar decompile / NeoForge 1.21.x)
    foreach ($rel in @(
            'src\main\resources\META-INF\neoforge.mods.toml',
            'src\main\resources\META-INF\mods.toml',
            'META-INF\neoforge.mods.toml'
        )) {
        $toml = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $toml)) { continue }
        $tt = Get-Content -LiteralPath $toml -Raw -ErrorAction SilentlyContinue
        if (-not $tt) { continue }
        if ($tt -match '(?m)^\s*modId\s*=\s*"([^"]+)"') { $meta.mod_id = $Matches[1] }
        if ($tt -match '(?m)^\s*version\s*=\s*"([^"]+)"') { $meta.mod_version = $Matches[1] }
        if ($tt -match '(?m)^\s*displayName\s*=\s*"([^"]+)"') { $meta.mod_name = $Matches[1] }
        if ($tt -match '(?m)^\s*authors\s*=\s*"([^"]+)"') { $meta.mod_authors = $Matches[1] }
        if ($tt -match '(?m)^\s*license\s*=\s*"([^"]+)"') { $meta.mod_license = $Matches[1] }
        break
    }
    # Strip Gradle property placeholders like ${file.jarVersion} so archives get a real version.
    if ([string]$meta.mod_version -match '\$\{') {
        $cleaned = ([string]$meta.mod_version) -replace '\$\{[^}]+\}', '' -replace '[^A-Za-z0-9._+-]', ''
        if (-not $cleaned -or $cleaned -eq '+mc' -or $cleaned.Length -lt 1) { $cleaned = '1.0.0' }
        $meta.mod_version = $cleaned.Trim('+','-','.')
        if (-not $meta.mod_version) { $meta.mod_version = '1.0.0' }
    }

    $bg = Join-Path $Root 'build.gradle'
    if (Test-Path $bg) {
        $t = Get-Content $bg -Raw
        if ($t -match "group\s*=\s*'([^']+)'") { $meta.mod_group = $Matches[1] }
        if ($t -match "archivesName\s*=\s*'([^']+)'") {
            $meta.mod_id = $Matches[1]
            $meta.mod_name = $Matches[1]
        }
        if ($t -match "mod_name\s*:\s*'([^']+)'") { $meta.mod_name = $Matches[1] }
        if ($t -match "mod_authors\s*:\s*'([^']+)'") { $meta.mod_authors = $Matches[1] }
        if ($t -match "mod_description\s*:\s*'([^']+)'") { $meta.mod_desc = $Matches[1] }
        if ($t -match "mod_license\s*:\s*'([^']+)'") { $meta.mod_license = $Matches[1] }
        if ($t -match "mod_id\s*:\s*'([^']+)'") { $meta.mod_id = $Matches[1] }
    }
    $java = Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -ErrorAction SilentlyContinue |
        Select-String -Pattern '@Mod\(' -List | Select-Object -First 1
    if ($java) {
        $pkg = Select-String -Path $java.Path -Pattern '^package\s+([\w\.]+);' | Select-Object -First 1
        if ($pkg) { $meta.mod_group = $pkg.Matches[0].Groups[1].Value }
    }
    return $meta
}

function Test-SourceNeedsLibrary {
    param([string]$Root, [string]$Pattern)
    $hit = Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue |
        Select-String -Pattern $Pattern -SimpleMatch:$false -List | Select-Object -First 1
    return [bool]$hit
}

function Write-GradleScaffold {
    param(
        [string]$Root,
        [hashtable]$Meta,
        [string]$LocalLibs,
        $DepPlan = $null
    )

    $props = @"
# Generated by Convert-Forge1201-ToNeoForge262 (experimental)
org.gradle.jvmargs=-Xmx4G
org.gradle.daemon=true
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.configuration-cache=false

minecraft_version=$MinecraftVersion
minecraft_version_range=[$MinecraftVersion]
neo_version=$NeoVersion

mod_id=$($Meta.mod_id)
mod_name=$($Meta.mod_name)
mod_license=$($Meta.mod_license)
mod_version=$($Meta.mod_version)+mc$MinecraftVersion-neoforge
mod_group_id=$($Meta.mod_group)
mod_authors=$($Meta.mod_authors)
mod_description=$($Meta.mod_desc)

geckolib_version=$GeckoLibVersion
smartbrainlib_version=$SmartBrainLibVersion
"@
    [System.IO.File]::WriteAllText((Join-Path $Root 'gradle.properties'), $props.Trim() + "`r`n")
    # Pin Gradle JVM to destination JDK (Java 25 for NeoForge 26.2) so installer/agent
    # builds ignore a stale Java-8 JAVA_HOME. Best-effort at scaffold time.
    $null = Set-ProjectDestinationJavaHome -ProjectRoot $Root -FallbackJavaMajor 25 -RequiredMajor 25

    $settings = @"
pluginManagement {
    repositories {
        gradlePluginPortal()
        maven { url = 'https://maven.neoforged.net/releases' }
        mavenCentral()
    }
}

plugins {
    id 'org.gradle.toolchains.foojay-resolver-convention' version '1.0.0'
}

rootProject.name = '$($Meta.mod_id)-neoforge-$MinecraftVersion'
$(if ($DepPlan -and $DepPlan.IncludeBuildBlock) { "`r`n$($DepPlan.IncludeBuildBlock)" } else { '' })
"@
    [System.IO.File]::WriteAllText((Join-Path $Root 'settings.gradle'), $settings.Trim() + "`r`n")

    $localRepoBlock = ''
    if ($LocalLibs -and (Test-Path $LocalLibs)) {
        $localPath = $LocalLibs.Replace('\', '/')
        $localRepoBlock = @"

    // Local pre-downloaded dependency jars (optional fallback)
    flatDir {
        dirs '$localPath'
    }
"@
    }

    # Extra implementation / toml / maven repos come from the dependency pipeline.
    $extraImpl = '    // No extra mod dependencies detected'
    $extraToml = ''
    $extraRepos = ''
    if ($DepPlan) {
        if ($DepPlan.ImplementationBlock) { $extraImpl = $DepPlan.ImplementationBlock }
        if ($DepPlan.TomlBlock) { $extraToml = $DepPlan.TomlBlock }
        if ($DepPlan.RepositoryBlock) { $extraRepos = $DepPlan.RepositoryBlock }
    }

    $build = @"
plugins {
    id 'java-library'
    id 'maven-publish'
    id 'net.neoforged.moddev' version '$ModDevGradleVersion'
    id 'idea'
}

tasks.named('wrapper', Wrapper).configure {
    distributionType = Wrapper.DistributionType.BIN
}

version = mod_version
group = mod_group_id

base {
    archivesName = mod_id
}

java.toolchain.languageVersion = JavaLanguageVersion.of(25)

sourceSets.main.resources {
    srcDir('src/generated/resources')
}

neoForge {
    version = project.neo_version

    runs {
        client {
            client()
            systemProperty 'neoforge.enabledGameTestNamespaces', project.mod_id
        }
        server {
            server()
            programArgument '--nogui'
        }
        configureEach {
            systemProperty 'forge.logging.markers', 'REGISTRIES'
            logLevel = org.slf4j.event.Level.DEBUG
        }
    }

    mods {
        "`${mod_id}" {
            sourceSet(sourceSets.main)
        }
    }
}

repositories {
    mavenCentral()
    maven { url = 'https://maven.neoforged.net/releases' }
    maven {
        name = 'GeckoLib'
        url = 'https://dl.cloudsmith.io/public/geckolib3/geckolib/maven/'
        content { includeGroupAndSubgroups('com.geckolib') }
    }
    maven {
        name = 'Tslat'
        url = 'https://dl.cloudsmith.io/public/tslat/tslat/maven/'
    }
    maven {
        name = 'BlameJared'
        url = 'https://maven.blamejared.com'
    }
    maven {
        name = 'Modrinth'
        url = 'https://api.modrinth.com/maven'
    }
    flatDir {
        dirs 'libs'
    }
$extraRepos
$localRepoBlock
}

dependencies {
$extraImpl
}

var generateModMetadata = tasks.register('generateModMetadata', ProcessResources) {
    var replaceProperties = [
            minecraft_version      : minecraft_version,
            minecraft_version_range: minecraft_version_range,
            neo_version            : neo_version,
            mod_id                 : mod_id,
            mod_name               : mod_name,
            mod_license            : mod_license,
            mod_version            : mod_version,
            mod_authors            : mod_authors,
            mod_description        : mod_description,
            geckolib_version       : geckolib_version,
            smartbrainlib_version  : smartbrainlib_version
    ]
    inputs.properties replaceProperties
    expand replaceProperties
    from 'src/main/templates'
    into 'build/generated/sources/modMetadata'
}

sourceSets.main.resources.srcDir generateModMetadata
neoForge.ideSyncTask generateModMetadata

tasks.withType(JavaCompile).configureEach {
    options.encoding = 'UTF-8'
    options.release = 25
}

idea {
    module {
        downloadSources = true
        downloadJavadoc = true
    }
}
"@
    [System.IO.File]::WriteAllText((Join-Path $Root 'build.gradle'), $build.Trim() + "`r`n")

    $tomlDir = Join-Path $Root 'src\main\templates\META-INF'
    New-Item -ItemType Directory -Path $tomlDir -Force | Out-Null
    $toml = @"
modLoader="javafml"
loaderVersion="[4,)"
license="`${mod_license}"

[[mods]]
modId="`${mod_id}"
version="`${mod_version}"
displayName="`${mod_name}"
authors="`${mod_authors}"
description='''`${mod_description}'''

[[dependencies.`${mod_id}]]
modId="neoforge"
type="required"
versionRange="[`${neo_version},)"
ordering="NONE"
side="BOTH"

[[dependencies.`${mod_id}]]
modId="minecraft"
type="required"
versionRange="`${minecraft_version_range}"
ordering="NONE"
side="BOTH"
$extraToml
"@
    [System.IO.File]::WriteAllText((Join-Path $tomlDir 'neoforge.mods.toml'), $toml.Trim() + "`r`n")

    $pack = @"
{
  "pack": {
    "min_format": 107,
    "max_format": 107,
    "description": "$($Meta.mod_name) $MinecraftVersion"
  }
}
"@
    [System.IO.File]::WriteAllText((Join-Path $Root 'src\main\resources\pack.mcmeta'), $pack.Trim() + "`r`n")

    # Remove legacy/source mod metadata from resources so generated templates win.
    # Critical: NeoForge 1.21.x jars leave neoforge.mods.toml with old minecraft versionRange
    # (e.g. [1.21.8]) which causes loader rejection even when the scaffold targets 26.2.
    $metaInf = Join-Path $Root 'src\main\resources\META-INF'
    foreach ($name in @('mods.toml', 'neoforge.mods.toml', 'mods.toml.template', 'MANIFEST.MF')) {
        $p = Join-Path $metaInf $name
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force
            Write-Info "Removed resources/META-INF/$name (using templates/neoforge.mods.toml)"
        }
    }
    if ((Test-Path -LiteralPath $metaInf) -and -not (Get-ChildItem -LiteralPath $metaInf -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Remove-Item -LiteralPath $metaInf -Force -ErrorAction SilentlyContinue
    }
}

function Get-Srg1201Map {
    if ($script:Srg1201Map) { return $script:Srg1201Map }
    $map = @{}
    foreach ($name in @('Srg1201Official.json', 'Srg1201Common.json')) {
        $p = Join-Path $ToolRoot "lib\$name"
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $obj = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) {
            $map[$prop.Name] = [string]$prop.Value
        }
    }
    $script:Srg1201Map = $map
    Write-Info ("SRG map entries: {0}" -f $map.Count)
    return $map
}

function Invoke-MechanicalJavaRewrites {
    param(
        [string]$Root,
        [AllowEmptyString()][string]$ModId = ''
    )

    $srgMap = Get-Srg1201Map
    $compatPkg = Get-Legacy262CompatPackage -ModId $ModId
    $compatFqcn = "$compatPkg.Legacy262Compat"
    $compatRel = ($compatPkg -replace '\.', '\') + '\Legacy262Compat.java'
    $srgEval = {
        param($m)
        $k = $m.Value
        if ($srgMap.ContainsKey($k)) { return $srgMap[$k] }
        return $k
    }
    $files = Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue
    $touched = 0
    $cutoutIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        $o = $t
        foreach ($m in [regex]::Matches($t, 'ItemBlockRenderTypes\.setRenderLayer\([^;]*?ModBlocks\.([A-Z0-9_]+)[^;]*?ChunkSectionLayer\.CUTOUT\s*\)')) {
            [void]$cutoutIds.Add($m.Groups[1].Value.ToLowerInvariant())
        }

        # --- MCreator 1.20.1 Vineflower: broken nearest-entity comparator ---
        $t = [regex]::Replace($t,
            '\.stream\(\)\.sorted\(\(\(<undefinedtype>\)\(new Object\(\)\s*\{[\s\S]*?compareDistOf\((\w+),\s*(\w+),\s*(\w+)\)\)\.findFirst\(\)\.orElse\(\(Object\)null\)',
            '.stream().sorted(Comparator.comparingDouble(_e -> _e.distanceToSqr($1, $2, $3))).findFirst().orElse(null)')

        if ($srgMap.Count -gt 0) {
            $t = [regex]::Replace($t, '\b[fm]_\d+_\b', $srgEval)
        }

        # --- Forge packages -> NeoForge (order matters: specific before broad) ---
        $t = $t -replace 'net\.minecraftforge\.fml\.common\.Mod\.EventBusSubscriber', 'net.neoforged.fml.common.EventBusSubscriber'
        $t = $t -replace 'net\.minecraftforge\.fml\.common\.Mod', 'net.neoforged.fml.common.Mod'
        $t = $t -replace 'net\.neoforged\.fml\.common\.Mod\.EventBusSubscriber', 'net.neoforged.fml.common.EventBusSubscriber'
        $t = $t -replace 'net\.minecraftforge\.fml\.javafmlmod\.FMLJavaModLoadingContext', 'net.neoforged.fml.javafmlmod.FMLJavaModLoadingContext'
        $t = $t -replace 'net\.minecraftforge\.fml\.ModLoadingContext', 'net.neoforged.fml.ModLoadingContext'
        $t = $t -replace 'net\.minecraftforge\.fml\.config\.ModConfig', 'net.neoforged.fml.config.ModConfig'
        $t = $t -replace 'net\.minecraftforge\.common\.ForgeConfigSpec', 'net.neoforged.neoforge.common.ModConfigSpec'
        $t = $t -replace '\bForgeConfigSpec\b', 'ModConfigSpec'
        $t = $t -replace 'net\.minecraftforge\.api\.distmarker\.Dist', 'net.neoforged.api.distmarker.Dist'
        $t = $t -replace 'net\.minecraftforge\.eventbus\.api', 'net.neoforged.bus.api'
        $t = $t -replace 'net\.minecraftforge\.eventbus\.api\.SubscribeEvent', 'net.neoforged.bus.api.SubscribeEvent'
        $t = $t -replace 'net\.minecraftforge\.eventbus\.api\.IEventBus', 'net.neoforged.bus.api.IEventBus'
        $t = $t -replace 'net\.minecraftforge\.event\.entity\.EntityAttributeCreationEvent', 'net.neoforged.neoforge.event.entity.EntityAttributeCreationEvent'
        $t = $t -replace 'net\.minecraftforge\.client\.event\.EntityRenderersEvent', 'net.neoforged.neoforge.client.event.EntityRenderersEvent'
        $t = $t -replace 'net\.minecraftforge\.client\.event\.ViewportEvent', 'net.neoforged.neoforge.client.event.ViewportEvent'
        $t = $t -replace 'net\.minecraftforge\.client\.event\.', 'net.neoforged.neoforge.client.event.'
        $t = $t -replace 'net\.minecraftforge\.event\.entity\.living\.', 'net.neoforged.neoforge.event.entity.living.'
        $t = $t -replace 'net\.minecraftforge\.event\.entity\.player\.', 'net.neoforged.neoforge.event.entity.player.'
        $t = $t -replace 'net\.minecraftforge\.event\.level\.', 'net.neoforged.neoforge.event.level.'
        $t = $t -replace 'net\.minecraftforge\.common\.MinecraftForge', 'net.neoforged.neoforge.common.NeoForge'
        $t = $t -replace 'MinecraftForge\.EVENT_BUS', 'NeoForge.EVENT_BUS'
        $t = $t -replace 'net\.minecraftforge\.registries\.DeferredRegister', 'net.neoforged.neoforge.registries.DeferredRegister'
        $t = $t -replace 'net\.minecraftforge\.registries\.RegistryObject', 'net.neoforged.neoforge.registries.DeferredHolder'
        $t = $t -replace 'net\.minecraftforge\.registries\.ForgeRegistries', 'net.minecraft.core.registries.BuiltInRegistries'
        $t = $t -replace '\bForgeRegistries\.SOUND_EVENTS\b', 'BuiltInRegistries.SOUND_EVENT'
        $t = $t -replace '\bForgeRegistries\.BLOCKS\b', 'BuiltInRegistries.BLOCK'
        $t = $t -replace '\bForgeRegistries\.ITEMS\b', 'BuiltInRegistries.ITEM'
        $t = $t -replace '\bForgeRegistries\.ENTITY_TYPES\b', 'BuiltInRegistries.ENTITY_TYPE'
        $t = $t -replace '\bForgeRegistries\.BLOCK_ENTITY_TYPES\b', 'BuiltInRegistries.BLOCK_ENTITY_TYPE'
        $t = $t -replace '\bForgeRegistries\.FEATURES\b', 'BuiltInRegistries.FEATURE'
        $t = $t -replace '\bForgeRegistries\.MOB_EFFECTS\b', 'BuiltInRegistries.MOB_EFFECT'
        # leftover catch-all (after specifics)
        $t = $t -replace 'net\.minecraftforge\.', 'net.neoforged.neoforge.'
        # Fix over-prefix from catch-all (api/fml live under net.neoforged.* not neoforge.*)
        $t = $t -replace 'net\.neoforged\.neoforge\.api\.distmarker', 'net.neoforged.api.distmarker'
        $t = $t -replace 'net\.neoforged\.neoforge\.fml\.', 'net.neoforged.fml.'
        $t = $t -replace 'net\.neoforged\.neoforge\.bus\.', 'net.neoforged.bus.'
        $t = $t -replace 'net\.neoforged\.neoforge\.eventbus\.api', 'net.neoforged.bus.api'

        # --- TickEvent (safe: do NOT map whole TickEvent package to ServerTickEvent) ---
        # Client
        $t = $t -replace 'import\s+net\.minecraftforge\.event\.TickEvent\.Phase;', ''
        $t = $t -replace 'import\s+net\.minecraftforge\.event\.TickEvent;', "import net.neoforged.neoforge.client.event.ClientTickEvent;`r`nimport net.neoforged.neoforge.event.tick.ServerTickEvent;"
        $t = $t -replace 'import\s+net\.neoforged\.neoforge\.event\.TickEvent\.Phase;', ''
        $t = $t -replace 'import\s+net\.neoforged\.neoforge\.event\.TickEvent;', "import net.neoforged.neoforge.client.event.ClientTickEvent;`r`nimport net.neoforged.neoforge.event.tick.ServerTickEvent;"
        $t = $t -replace 'TickEvent\.ClientTickEvent', 'ClientTickEvent'
        $t = $t -replace 'TickEvent\.ServerTickEvent', 'ServerTickEvent'
        # phase END handlers ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ Post events (common 1.20.1 pattern)
        $t = [regex]::Replace($t,
            '(?s)public\s+static\s+void\s+(\w+)\s*\(\s*ClientTickEvent\s+(\w+)\s*\)\s*\{\s*if\s*\(\s*\2\.phase\s*==\s*TickEvent\.Phase\.END\s*\)\s*\{(.*?)\}\s*\}',
            'public static void $1(ClientTickEvent.Post $2) {$3}')
        $t = [regex]::Replace($t,
            '(?s)public\s+static\s+void\s+(\w+)\s*\(\s*ServerTickEvent\s+(\w+)\s*\)\s*\{\s*if\s*\(\s*\2\.phase\s*==\s*TickEvent\.Phase\.END\s*\)\s*\{(.*?)\}\s*\}',
            'public static void $1(ServerTickEvent.Post $2) {$3}')
        $t = [regex]::Replace($t,
            '(?s)public\s+void\s+(\w+)\s*\(\s*ServerTickEvent\s+(\w+)\s*\)\s*\{\s*if\s*\(\s*\2\.phase\s*==\s*TickEvent\.Phase\.END\s*\)\s*\{(.*?)\}\s*\}',
            'public void $1(ServerTickEvent.Post $2) {$3}')
        # Remaining phase checks
        $t = $t -replace 'public void tick\(ServerTickEvent event\)', 'public void tick(ServerTickEvent.Post event)'
        $t = $t -replace '(\w+)\.phase\s*==\s*Phase\.END', 'true /* was $1.phase END */'
        $t = $t -replace '(\w+)\.phase\s*==\s*TickEvent\.Phase\.END', '($1 instanceof ClientTickEvent.Post || $1 instanceof ServerTickEvent.Post)'
        $t = $t -replace '(\w+)\.phase\s*==\s*TickEvent\.Phase\.START', '($1 instanceof ClientTickEvent.Pre || $1 instanceof ServerTickEvent.Pre)'
        $t = $t -replace 'TickEvent\.Phase\.END', '/* END */ true'
        $t = $t -replace 'TickEvent\.Phase\.START', '/* START */ true'

        # Bus subscriber: FORGE bus -> GAME bus
        $t = $t -replace 'Mod\.EventBusSubscriber\.Bus\.FORGE', 'Mod.EventBusSubscriber.Bus.GAME'

        # --- Minecraft 26.x: ResourceLocation renamed to Identifier ---
        $t = $t -replace 'net\.minecraft\.resources\.ResourceLocation', 'net.minecraft.resources.Identifier'
        $t = $t -replace '\bResourceLocation\b', 'Identifier'
        # constructors already converted or: new Identifier(ns, path) / fromNamespaceAndPath
        $t = [regex]::Replace($t, 'new\s+Identifier\(\s*([^,]+)\s*,\s*([^\)]+)\)', 'Identifier.fromNamespaceAndPath($1, $2)')
        # undo double-fromNamespace if we already had fromNamespaceAndPath on Identifier
        $t = $t -replace 'Identifier\.fromNamespaceAndPath', 'Identifier.fromNamespaceAndPath'

        # --- Entity / level accessors (1.20.1 fields -> methods) ---
        # IMPORTANT: never rewrite package paths like net.minecraft.world.level.Level
        # Only rewrite Entity field access: this.level / entity.level
        $t = Convert-LevelClientSideAccess $t
        $t = Convert-NeoForge262ApiMoves -Text $t -ModId $ModId
        $t = $t -replace '(?m)^\s*import\s+net\.minecraft\.client\.renderer\.ItemBlockRenderTypes;\s*\r?\n', ''
        $t = $t -replace '(?m)^\s*ItemBlockRenderTypes\.setRenderLayer\([^;]+;\s*\r?\n', ''
        # setMaxUpStep removed - comment out whole statement line-ish
        $t = [regex]::Replace($t, '(?m)^(\s*)(.*)\.setMaxUpStep\s*\(([^;]*)\)\s*;\s*$', '$1// LEGACY: $2.setMaxUpStep($3); // removed in 26.x')
        # BlockPos.getCenter -> Vec3.atCenterOf (simple receivers; chained forms handled in 26.2 API pass)
        $t = [regex]::Replace($t, '(?<![\w.])([a-zA-Z_]\w*)\.getCenter\(\)', {
                param($m)
                $recv = $m.Groups[1].Value
                if ($recv -match '^(?i)(visualBox|box|aabb)$') { return $m.Value }
                "net.minecraft.world.phys.Vec3.atCenterOf($recv)"
            })
        # Common chained BlockPos centers: feet.relative(dir).getCenter()
        $t = [regex]::Replace($t,
            '([a-zA-Z_]\w*(?:\([^)]*\))?\.relative\([^)]+\))\.getCenter\(\)',
            'net.minecraft.world.phys.Vec3.atCenterOf($1)')

        # EntityType.Builder.build("id")
        $t = [regex]::Replace($t, '\.build\(\s*"[^"]*"\s*\)', '.build()')

        # --- GeckoLib 4 -> 5 packages ---
        $t = $t -replace 'software\.bernie\.geckolib', 'com.geckolib'
        $t = $t -replace 'com\.geckolib\.core\.animatable\.instance', 'com.geckolib.animatable.instance'
        $t = $t -replace 'com\.geckolib\.core\.animation', 'com.geckolib.animation'
        $t = $t -replace 'com\.geckolib\.animation\.AnimatableManager', 'com.geckolib.animatable.manager.AnimatableManager'
        $t = $t -replace 'com\.geckolib\.core\.object\.PlayState', 'com.geckolib.animation.object.PlayState'
        $t = $t -replace 'com\.geckolib\.cache\.object\.BakedGeoModel', 'com.geckolib.cache.model.BakedGeoModel'
        $t = $t -replace 'com\.geckolib\.animation\.AnimationController\.State', 'com.geckolib.animation.object.PlayState'
        # AnimationController no longer takes animatable as first constructor arg
        $t = $t -replace 'new\s+AnimationController<>\s*\(\s*this\s*,\s*', 'new AnimationController<>('
        $t = $t -replace 'new\s+AnimationController\s*\(\s*this\s*,\s*', 'new AnimationController('
        # Vineflower wraps add(controller) as add(new AnimationController[]{...}) which GeckoLib 5 ignores/mis-bakes
        $t = $t -replace 'data\.add\(new AnimationController\[\]\{new AnimationController\(', 'data.add(new AnimationController<>('
        $t = $t -replace 'controllers\.add\(new AnimationController\[\]\{new AnimationController\(', 'controllers.add(new AnimationController<>('
        $t = $t -replace '\)\}\);(\s*data\.add\(new AnimationController)', ');$1'
        $t = $t -replace 'new AnimationController<>\("([^"]+)", (\d+), this::(\w+)\)\}\);', 'new AnimationController<>("$1", $2, this::$3));'
        # GeoEntityRenderer is now (Animatable, RenderState)
        $t = $t -replace 'extends\s+GeoEntityRenderer<([^,>]+)>', 'extends GeoEntityRenderer<$1, net.minecraft.client.renderer.entity.state.LivingEntityRenderState>'
        # Drop GeckoLib4 preRender / getRenderType overrides (signatures changed)
        $t = [regex]::Replace($t, '(?ms)\s*public\s+RenderType\s+getRenderType\s*\([^)]*\)\s*\{[^}]*\}', '')
        $t = [regex]::Replace($t, '(?ms)\s*public\s+void\s+preRender\s*\([^)]*\)\s*\{[\s\S]*?super\.preRender\([^;]+;\s*\}', '')
        # GeoModel resource methods take GeoRenderState; variant getTexture() cannot stay
        if ($t -match 'extends\s+GeoModel') {
            $t = $t -replace 'public\s+Identifier\s+getModelResource\s*\(\s*(\w+)\s+(\w+)\s*\)',
                'public Identifier getModelResource(com.geckolib.renderer.base.GeoRenderState $2)'
            $t = $t -replace 'public\s+Identifier\s+getTextureResource\s*\(\s*(\w+)\s+(\w+)\s*\)',
                'public Identifier getTextureResource(com.geckolib.renderer.base.GeoRenderState $2)'
            # GeoRenderState has no getTexture(); keep a real default PNG (unknown.png is missing -> purple/black).
            # A later pass substitutes the entity's TEXTURE synched default when present.
            $t = $t -replace '"textures/entities/" \+ \w+\.getTexture\(\) \+ "\.png"', '"textures/entities/toww_reborn.png"'
            $t = $t -replace '"geo/([^"]+)\.geo\.json"', '"$1"'
            $t = $t -replace '"animations/([^"]+)\.animation\.json"', '"$1"'
        }

        # Forge 1.20 PlayMessages client ctor is gone
        $t = [regex]::Replace($t, '(?ms)\s*public\s+\w+\s*\(\s*PlayMessages\.SpawnEntity\s+\w+\s*,\s*Level\s+\w+\s*\)\s*\{[^}]*\}', '')
        $t = $t -replace '(?m)^\s*import net\.neoforged\.neoforge\.network\.PlayMessages;\s*\r?\n', ''
        $t = $t -replace '(?m)^\s*import net\.minecraftforge\.network\.PlayMessages;\s*\r?\n', ''
        $t = [regex]::Replace($t, '(?ms)\s*public\s+Packet(?:<[^>]+>)?\s+getAddEntityPacket\s*\(\s*\)\s*\{\s*return\s+NetworkHooks\.getEntitySpawningPacket\([^;]+;\s*\}', '')
        $t = $t -replace '(?m)^\s*import net\.neoforged\.neoforge\.network\.NetworkHooks;\s*\r?\n', ''

        # DeferredHolder needs (registry type, holder type)
        $t = $t -replace 'DeferredHolder<\s*EntityType<([^>]+)>\s*>', 'DeferredHolder<EntityType<?>, EntityType<$1>>'
        $t = $t -replace 'private static <T extends Entity> DeferredHolder<EntityType<T>>', 'private static <T extends Entity> DeferredHolder<EntityType<?>, EntityType<T>>'
        $t = $t -replace 'DeferredHolder<Block>(?!\s*,)', 'DeferredHolder<Block, Block>'
        $t = $t -replace 'DeferredHolder<Item>(?!\s*,)', 'DeferredHolder<Item, Item>'
        $t = $t -replace 'DeferredHolder<Feature<\?>>(?!\s*,)', 'DeferredHolder<Feature<?>, Feature<?>>'
        $t = $t -replace 'DeferredHolder<SoundEvent>(?!\s*,)', 'DeferredHolder<SoundEvent, SoundEvent>'
        $t = $t -replace 'DeferredHolder<MobEffect>(?!\s*,)', 'DeferredHolder<MobEffect, MobEffect>'
        $t = $t -replace 'DeferredHolder<CreativeModeTab>(?!\s*,)', 'DeferredHolder<CreativeModeTab, CreativeModeTab>'

        # 26.2 synched data builder
        $t = $t -replace 'protected void defineSynchedData\(\)', 'protected void defineSynchedData(net.minecraft.network.syncher.SynchedEntityData.Builder builder)'
        $t = $t -replace 'super\.defineSynchedData\(\)', 'super.defineSynchedData(builder)'
        $t = $t -replace 'this\.entityData\.define\(', 'builder.define('

        # MobType removed
        $t = [regex]::Replace($t, '(?ms)\s*public\s+MobType\s+getMobType\s*\(\s*\)\s*\{[^}]*\}', '')
        $t = $t -replace 'import net\.minecraft\.world\.entity\.MobSpawnType;', 'import net.minecraft.world.entity.EntitySpawnReason;'
        $t = $t -replace '(?<![\w.])MobSpawnType\b', 'EntitySpawnReason'
        $t = $t -replace 'import net\.minecraft\.world\.entity\.MobType;', ''
        $t = $t -replace 'import net\.minecraft\.world\.level\.pathfinder\.BlockPathTypes;', 'import net.minecraft.world.level.pathfinder.PathType;'
        $t = $t -replace '\bBlockPathTypes\b', 'PathType'
        $t = $t -replace 'import net\.minecraft\.world\.entity\.projectile\.AbstractArrow;', 'import net.minecraft.world.entity.projectile.arrow.AbstractArrow;'
        $t = $t -replace 'import net\.minecraft\.world\.entity\.projectile\.ThrownPotion;', 'import net.minecraft.world.entity.projectile.throwableitemprojectile.AbstractThrownPotion;'
        $t = $t -replace 'import net\.minecraft\.world\.entity\.projectile\.thrown\.ThrownPotion;', 'import net.minecraft.world.entity.projectile.throwableitemprojectile.AbstractThrownPotion;'
        $t = $t -replace '\bThrownPotion\b', 'AbstractThrownPotion'
        $t = $t -replace 'import net\.minecraft\.world\.entity\.SpawnPlacements\.Type;', 'import net.minecraft.world.entity.SpawnPlacementTypes;'
        $t = $t -replace 'SpawnPlacements\.Type', 'SpawnPlacementTypes'
        $t = $t -replace 'import com\.mojang\.blaze3d\.platform\.GlStateManager(?:\.\w+)?;', 'import com.mojang.blaze3d.systems.RenderSystem;'
        $t = $t -replace 'import net\.minecraftforge\.network\.simple\.SimpleChannel;', ''
        $t = $t -replace 'import net\.neoforged\.neoforge\.network\.simple\.SimpleChannel;', ''
        $t = $t -replace 'import net\.minecraftforge\.network\.NetworkRegistry;', ''
        $t = $t -replace 'import net\.neoforged\.neoforge\.network\.NetworkRegistry;', ''
        $t = $t -replace 'import net\.minecraftforge\.network\.NetworkEvent;', ''
        $t = $t -replace 'import net\.neoforged\.neoforge\.network\.NetworkEvent;', ''
        $t = [regex]::Replace($t, 'public static final SimpleChannel PACKET_HANDLER = [^;]+;', 'public static final Object PACKET_HANDLER = new Object();')
        $t = [regex]::Replace($t,
            '(?s)public static <T> void addNetworkMessage\([^)]*\)\s*\{[^}]*\}',
            'public static <T> void addNetworkMessage(Class<T> messageType, Object encoder, Object decoder, Object messageConsumer) { /* 26.2 payloads: RegisterPayloadHandlersEvent */ }')
        # GeckoLib only: do not rename vanilla net.minecraft.world.entity.AnimationState
        if ($t -match 'import\s+com\.geckolib\b' -or $t -match 'import\s+software\.bernie\b' -or $t -match '\bcom\.geckolib\.' -or $t -match '\bsoftware\.bernie\.') {
            $t = $t -replace 'com\.geckolib\.animation\.AnimationState', 'com.geckolib.animation.state.AnimationTest'
            $t = $t -replace '(?<![\w.])AnimationState\b', 'AnimationTest'
            $t = $t -replace 'event\.getController\(\)\.getAnimationState\(\)\s*==\s*State\.STOPPED', 'event.controller().getAnimationState() == PlayState.STOP'
            $t = $t -replace 'event\.getController\(\)\.setAnimation\(', 'event.setAnimation('
            $t = $t -replace 'event\.getController\(\)\.forceAnimationReset\(\)', ''
            $t = $t -replace 'event\.controller\(\)\.stop\(\);', ''
            $t = $t -replace 'event\.controller\(\)\.getAnimationState\(\) == PlayState\.STOP', 'true'
            $t = $t -replace 'event\.getController\(\)', 'event.controller()'
        }
        $t = $t -replace '\.create\(serverWorld\)', '.create(serverWorld, EntitySpawnReason.BREEDING)'
        $t = $t -replace 'SoundEvent\.accept\(', 'SoundEvent.createVariableRangeEvent('
        $t = $t -replace 'SoundEvent\.sendSystemMessage\(', 'SoundEvent.createVariableRangeEvent('
        $t = $t -replace 'tabData\.sendSystemMessage\(', 'tabData.accept('
        $t = $t -replace 'SpawnPlacements\.addEffect\(', 'SpawnPlacements.register('
        $t = $t -replace '(?<![\w.])Type\.ON_GROUND', 'net.minecraft.world.entity.SpawnPlacementTypes.ON_GROUND'
        $t = $t -replace 'event\.getLimbSwingAmount\(\)', '0.0F'
        $t = $t -replace 'void m_5993_\(Entity', 'void awardKillScore(Entity'
        $t = $t -replace 'this\.ANIMATION_SPEED', 'this.deathTime'
        $t = $t -replace 'protected void dropCustomDeathLoot\(net\.minecraft\.server\.level\.ServerLevel level, DamageSource (\w+), int \w+, boolean (\w+)\)', 'protected void dropCustomDeathLoot(net.minecraft.server.level.ServerLevel level, DamageSource $1, boolean $2)'
        $t = $t -replace 'super\.m_7472_\([^;]+;', 'super.dropCustomDeathLoot(level, source, recentlyHitIn);'
        $t = $t -replace 'this\.spawnAtLocation\(new ItemStack', 'this.spawnAtLocation(level, new ItemStack'
        $t = $t -replace '\.getType\(serverWorld\)', '.create(serverWorld, EntitySpawnReason.BREEDING)'
        $t = $t -replace 'Builder\.getYRot\(', 'EntityType.Builder.of('
        $t = $t -replace '(?<!EntityType\.)Builder\.of\(', 'EntityType.Builder.of('
        $t = $t -replace '\.setCustomClientFactory\([^)]+\)', ''
        $t = $t -replace '\.getXRot\(\)', ''
        $t = $t -replace '\.getType\(([0-9.F]+),\s*([0-9.F]+)\)', '.sized($1, $2)'
        $t = [regex]::Replace($t, '(?s)public static void init\(\) \{\s*(?:SpawnPlacements\.(?:register|addEffect)\(|// SpawnPlacements\.register\()[\s\S]*?\}\);\s*\}', 'public static void init() { }')
        $t = $t -replace 'boolean canAttackType\(ItemStack stack\)', 'boolean isFood(ItemStack stack)'
        $t = $t -replace 'extends\s+MobRenderer<([^,>]+),\s*([^>]+)>', 'extends MobRenderer<$1, net.minecraft.client.renderer.entity.state.LivingEntityRenderState, $2>'

        # NeoForge 26 EventBusSubscriber has no nested Bus
        $t = $t -replace 'import net\.neoforged\.fml\.common\.EventBusSubscriber\.Bus;\s*', ''
        $t = $t -replace 'import net\.neoforged\.fml\.common\.Mod\.EventBusSubscriber\.Bus;\s*', ''
        $t = [regex]::Replace($t, '(?s)@EventBusSubscriber\(\s*bus\s*=\s*Bus\.MOD\s*,\s*value\s*=\s*\{?\s*Dist\.CLIENT\s*\}?\s*\)', '@EventBusSubscriber(Dist.CLIENT)')
        $t = [regex]::Replace($t, '(?s)@EventBusSubscriber\(\s*value\s*=\s*\{?\s*Dist\.CLIENT\s*\}?\s*,\s*bus\s*=\s*Bus\.MOD\s*\)', '@EventBusSubscriber(Dist.CLIENT)')
        $t = [regex]::Replace($t, '(?s)@EventBusSubscriber\(\s*bus\s*=\s*Bus\.MOD\s*\)', '@EventBusSubscriber')
        $t = [regex]::Replace($t, '(?s)@EventBusSubscriber\(\s*bus\s*=\s*Bus\.GAME\s*\)', '@EventBusSubscriber')
        $t = [regex]::Replace($t, '@EventBusSubscriber\(\s*value\s*=\s*Dist\.CLIENT\s*,\s*bus\s*=\s*Bus\.MOD\s*\)', '@EventBusSubscriber(Dist.CLIENT)')

        $t = $t -replace 'LivingEvent\.LivingTickEvent', 'net.neoforged.neoforge.event.tick.EntityTickEvent.Post'
        $t = $t -replace 'TickEvent\.PlayerTickEvent', 'net.neoforged.neoforge.event.tick.PlayerTickEvent.Post'
        $t = $t -replace 'TickEvent\.LevelTickEvent', 'net.neoforged.neoforge.event.tick.LevelTickEvent.Post'
        $t = $t -replace 'TickEvent\.RenderTickEvent', 'net.neoforged.neoforge.client.event.RenderFrameEvent.Post'

        $t = $t -replace 'net\.minecraftforge\.common\.ForgeSpawnEggItem', 'net.minecraft.world.item.SpawnEggItem'
        $t = $t -replace 'net\.neoforged\.neoforge\.common\.ForgeSpawnEggItem', 'net.minecraft.world.item.SpawnEggItem'
        $t = $t -replace 'new\s+ForgeSpawnEggItem\s*\(([^,]+),\s*[^,]+,\s*[^,]+,\s*([^)]+)\)', 'new SpawnEggItem($2.spawnEgg($1.get()))'

        $t = $t -replace 'Supplier<NetworkEvent\.Context>', 'Object'
        $t = $t -replace 'NetworkEvent\.Context', 'Object'
        $t = $t -replace 'import net\.neoforged\.neoforge\.network\.NetworkEvent;\s*', ''

        $t = $t -replace 'import net\.minecraft\.world\.entity\.animal\.IronGolem;', 'import net.minecraft.world.entity.animal.golem.IronGolem;'
        $t = $t -replace 'import net\.minecraft\.client\.gui\.screens\.inventory\.EffectRenderingInventoryScreen;', ''
        $t = $t -replace '\.offset\(OffsetType\.XZ\)', ''
        $t = $t -replace '\.offset\(OffsetType\.XYZ\)', ''
        $t = $t -replace 'getItem\(\)\s*!=\s*this\.getName\(\)', 'getItem() != this.asItem()'
        $t = $t -replace 'super\.getFluidState\(state\)', 'Fluids.EMPTY.defaultFluidState()'
        $t = [regex]::Replace($t,
            'public BlockState updateShape\(BlockState state, Direction facing, BlockState facingState, LevelAccessor world, BlockPos currentPos, BlockPos facingPos\)',
            'protected BlockState updateShape(BlockState state, net.minecraft.world.level.LevelReader world, net.minecraft.world.level.ScheduledTickAccess ticks, BlockPos currentPos, Direction facing, BlockPos facingPos, BlockState facingState, net.minecraft.util.RandomSource random)')
        $t = $t -replace 'super\.updateShape\(state, facing, facingState, world, currentPos, facingPos\)', 'super.updateShape(state, world, ticks, currentPos, facing, facingPos, facingState, random)'
        $t = $t -replace 'world\.scheduleTick\(currentPos, Fluids\.WATER, Fluids\.WATER\.getTickDelay\(world\)\)', 'ticks.scheduleTick(currentPos, Fluids.WATER, Fluids.WATER.getTickDelay(world))'

        # 26.2 EntityModel is EntityRenderState-typed, not Entity
        $t = $t -replace 'class (\w+)<T extends Entity> extends EntityModel<T>', 'class $1 extends EntityModel<net.minecraft.client.renderer.entity.state.LivingEntityRenderState>'
        $t = $t -replace 'void setupAnim\(T ', 'void setupAnim(net.minecraft.client.renderer.entity.state.LivingEntityRenderState '
        $t = $t -replace 'void renderToBuffer\(PoseStack ([^,]+), VertexConsumer ([^,]+), int ([^,]+), int ([^,]+), float [^,]+, float [^,]+, float [^,]+, float [^)]+\)', 'void renderToBuffer(PoseStack $1, VertexConsumer $2, int $3, int $4)'
        $t = $t -replace 'PartPose\.rotation\(([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^)]+)\)', 'PartPose.offsetAndRotation($1,$2,$3,$4,$5,$6)'
        $t = $t -replace 'meshdefinition\.bake\(\)', 'meshdefinition.getRoot()'
        $t = $t -replace '\.addBox\(\)\.addBox\(', '.addBox('
        $t = $t -replace '\.m_171480_\(\)\.', '.'
        $t = [regex]::Replace($t, 'public (\w+)\(ModelPart root\) \{\s*this\.', "public `$1(ModelPart root) {`r`n      super(root);`r`n      this.")
        $t = $t -replace '(Model(?:The_)?[\w]+)<[^>]+>', '$1'
        $t = $t -replace 'getTextureLocation\(\w+ entity\)', 'getTextureLocation(net.minecraft.client.renderer.entity.state.LivingEntityRenderState state)'
        $t = $t -replace 'new Identifier\("([^"]+)"\)', 'Identifier.parse("$1")'
        $t = $t -replace 'Identifier\.fromNamespaceAndPath\("([^"]*)"\)', 'Identifier.parse("$1")'
        $t = $t -replace 'Identifier\.parse\(""\)', 'Identifier.parse("minecraft:empty")'

        $t = $t -replace 'public boolean hurt\(DamageSource (\w+), float (\w+)\)', 'public boolean hurtServer(net.minecraft.server.level.ServerLevel level, DamageSource $1, float $2)'
        $t = $t -replace 'super\.hurt\((\w+), (\w+)\)', 'super.hurtServer(level, $1, $2)'
        $t = $t -replace 'public EntityDimensions getDimensions\(Pose ', 'public EntityDimensions getDefaultDimensions(Pose '
        $t = $t -replace 'super\.getDimensions\(', 'super.getDefaultDimensions('
        $t = $t -replace 'super\.finalizeSpawn\((\w+), (\w+), (\w+), (\w+), (\w+)\)', 'super.finalizeSpawn($1, $2, $3, $4)'
        $t = $t -replace 'public SpawnGroupData finalizeSpawn\(([^)]+), @Nullable CompoundTag \w+\)', 'public SpawnGroupData finalizeSpawn($1)'
        $t = $t -replace 'this\.dropFromLootTable\(\);', ''

        if ($t -match 'extends Animal' -and $t -notmatch 'boolean isFood\(') {
            $t = [regex]::Replace($t, '(public static void init\(\) \{\s*\})', "`$1`r`n`r`n   public boolean isFood(net.minecraft.world.item.ItemStack stack) { return false; }")
        }
        if ($t -match 'extends MobRenderer<' -and $t -notmatch 'createRenderState\(') {
            $t = [regex]::Replace($t, '(public \w+\((?:EntityRendererProvider\.)?Context[^\)]*\) \{[^}]+\})', "`$1`r`n`r`n   public net.minecraft.client.renderer.entity.state.LivingEntityRenderState createRenderState() { return new net.minecraft.client.renderer.entity.state.LivingEntityRenderState(); }")
        }
        $t = $t -replace 'void setupAnim\(T entity,', 'void setupAnim(net.minecraft.client.renderer.entity.state.LivingEntityRenderState entity,'
        $t = $t -replace 'void m_6973_\(T entity,', 'void setupAnim(net.minecraft.client.renderer.entity.state.LivingEntityRenderState entity,'
        $t = $t -replace ', red, green, blue, alpha\)', ')'
        $t = $t -replace 'new Identifier\(""\)', 'Identifier.parse("minecraft:empty")'
        $t = $t -replace 'Blocks\.([A-Z0-9_]+)\.getName\(\)', 'Blocks.$1.asItem()'
        $t = $t -replace 'finalizeSpawn\(([^,]+), ([^,]+), ([^,]+), ([^,]+), \(CompoundTag\)null\)', 'finalizeSpawn($1, $2, $3, $4)'
        $t = $t -replace 'this\.(\w+)\.renderToBuffer\(poseStack, vertexConsumer, packedLight, packedOverlay\)', 'this.$1.render(poseStack, vertexConsumer, packedLight, packedOverlay)'
        $t = [regex]::Replace($t, '(?s)public void addAdditionalSaveData\(DamageSource (\w+)\) \{\s*super\.addAdditionalSaveData\(\1\);\s*\}', 'public void die(DamageSource $1) { super.die($1); }')
        $t = [regex]::Replace($t, 'protected void defineSynchedData\(DamageSource (\w+), int \w+, boolean (\w+)\) \{\s*super\.defineSynchedData\([^;]+;\s*this\.spawnAtLocation\(', 'protected void dropCustomDeathLoot(net.minecraft.server.level.ServerLevel level, DamageSource $1, boolean $2) { super.dropCustomDeathLoot(level, $1, $2); this.spawnAtLocation(level, ')
        $t = [regex]::Replace($t, '(?s)public void readAdditionalSaveData\(Entity \w+, int \w+, DamageSource \w+\) \{\s*super\.readAdditionalSaveData\([^;]+;\s*\}', '')
        $t = $t -replace 'void m_7472_\(DamageSource', 'void dropCustomDeathLoot(net.minecraft.server.level.ServerLevel level, DamageSource'
        $t = $t -replace 'void m_6667_\(DamageSource', 'void die(DamageSource'
        $t = $t -replace 'super\.m_6667_\(source\)', 'super.die(source)'
        $t = $t -replace 'void m_6667_\(CompoundTag', 'void addAdditionalSaveData(net.minecraft.world.level.storage.ValueOutput'
        $t = $t -replace 'void m_5993_\(CompoundTag', 'void readAdditionalSaveData(net.minecraft.world.level.storage.ValueInput'
        $t = $t -replace 'void addAdditionalSaveData\(CompoundTag', 'void addAdditionalSaveData(net.minecraft.world.level.storage.ValueOutput'
        $t = $t -replace 'void readAdditionalSaveData\(CompoundTag', 'void readAdditionalSaveData(net.minecraft.world.level.storage.ValueInput'

        # Annotations
        $t = $t -replace 'import javax\.annotation\.Nullable;', 'import org.jetbrains.annotations.Nullable;'
        $t = $t -replace 'import javax\.annotation\.Nonnull;', 'import org.jetbrains.annotations.NotNull;'

        # Mod constructor injection hint
        if ($t -match 'FMLJavaModLoadingContext') {
            $t = $t -replace 'FMLJavaModLoadingContext\.get\(\)\.getModEventBus\(\)',
                '/* TODO inject IEventBus */ FMLJavaModLoadingContext.get().getModEventBus()'
        }

        # RegistryObject residual type name (import already DeferredHolder)
        $t = $t -replace '\bRegistryObject\b', 'DeferredHolder'

        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $touched++
        }
    }

    # ItemBlockRenderTypes was removed. Preserve CUTOUT intent in the model
    # metadata supported by NeoForge's model loader.
    $modelRoot = Join-Path $Root 'src\main\resources\assets'
    if (Test-Path -LiteralPath $modelRoot) {
        foreach ($id in $cutoutIds) {
            foreach ($model in @(Get-ChildItem -LiteralPath $modelRoot -Recurse -File -Filter "$id*.json" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '[\\/]models[\\/]block[\\/]' })) {
                try {
                    $json = Get-Content -LiteralPath $model.FullName -Raw | ConvertFrom-Json
                    if (-not $json.PSObject.Properties['render_type']) { $json | Add-Member NoteProperty render_type 'minecraft:cutout' }
                    [IO.File]::WriteAllText($model.FullName, ($json | ConvertTo-Json -Depth 100))
                } catch { Write-Warning "Could not add CUTOUT metadata to $($model.FullName): $($_.Exception.Message)" }
            }
        }
    }

    # JPMS: Legacy262Compat must live under a mod-scoped package. Shared
    # rb.legacy.converter.compat collides when two converted mods load together.
    $javaRoot = Join-Path $Root 'src\main\java'
    $legacySharedCompat = Join-Path $javaRoot 'rb\legacy\converter\compat\Legacy262Compat.java'
    if (Test-Path -LiteralPath $legacySharedCompat) {
        Remove-Item -LiteralPath $legacySharedCompat -Force -ErrorAction SilentlyContinue
    }

    $needsCompat = Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]rb[\\/]legacy[\\/]converter[\\/]compat[\\/]' } |
        Select-String -SimpleMatch $compatFqcn -Quiet
    if (-not $needsCompat) {
        # Also detect leftover shared FQCN from older converter runs.
        $needsCompat = Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]rb[\\/]legacy[\\/]converter[\\/]compat[\\/]' } |
            Select-String -SimpleMatch 'rb.legacy.converter.compat.Legacy262Compat' -Quiet
    }
    if ($needsCompat) {
        # Ensure call sites use the mod-scoped FQCN (idempotent rewrites).
        foreach ($cf in @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/]rb[\\/]legacy[\\/]converter[\\/]compat[\\/]' })) {
            $ct = [IO.File]::ReadAllText($cf.FullName)
            $co = $ct
            $ct = $ct.Replace('rb.legacy.converter.compat.Legacy262Compat', $compatFqcn)
            if ($ct -ne $co) { [IO.File]::WriteAllText($cf.FullName, $ct); $touched++ }
        }
        $compatPath = Join-Path $javaRoot $compatRel
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($compatPath)) | Out-Null
        $compat = @"
package $compatPkg;

import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.renderer.block.dispatch.BlockStateModel;
import net.minecraft.client.renderer.block.dispatch.BlockStateModelPart;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.Property;

/** Mechanical bridge for APIs removed between Minecraft 1.21.x and 26.2. Mod-scoped to avoid JPMS split packages. */
public final class Legacy262Compat {
    private Legacy262Compat() {}

    @SuppressWarnings("deprecation")
    public static List<BlockStateModelPart> modelParts(BlockStateModel model) {
        List<BlockStateModelPart> parts = new ArrayList<>();
        model.collectParts(RandomSource.create(), parts);
        return parts;
    }

    public static BlockState copyValue(BlockState target, Property.Value<?> value) {
        return copyCaptured(target, value);
    }

    @SuppressWarnings("unchecked")
    private static <T extends Comparable<T>> BlockState copyCaptured(BlockState target, Property.Value<T> value) {
        Property<T> property = (Property<T>) target.getBlock().getStateDefinition().getProperty(value.property().getName());
        return property == null ? target : target.setValue(property, value.value());
    }
}

"@
        [IO.File]::WriteAllText($compatPath, $compat)
    }
    return $touched
}

function Invoke-ExactPrimerMigrationRules {
    <#
    .SYNOPSIS
      Applies mechanical transforms for primer rule IDs selected STRICTLY after the detected source.
      Rule IDs come from PrimerChangeIndex via Get-PrimerMigrationRules (to > source only).
    #>
    param([string]$Root, $Profile, [string]$ModId)

    $rules = @(Get-PrimerMigrationRules -SourceVersion ([string]$Profile.SourceVersion))
    $touched = 0
    $javaRoot = Join-Path $Root 'src\main\java'
    $nl = [Environment]::NewLine

    foreach ($file in @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue)) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $original = $text

        if ($rules -contains 'legacy-direction-property') {
            $text = $text.Replace('import net.minecraft.world.level.block.state.properties.DirectionProperty;', 'import net.minecraft.world.level.block.state.properties.EnumProperty;')
            $text = $text.Replace('DirectionProperty', 'EnumProperty<Direction>')
            $text = $text.Replace('.getNormal()', '.getUnitVec3i()')
        }

        # 1.21.5: ArmorItem/SwordItem removed -> Item + Properties.humanoidArmor / Properties.sword
        if ($rules -contains 'armor-tool-item-components') {
            if ($text -match 'extends\s+ArmorItem\b') {
                $text = $text -replace 'import\s+net\.minecraft\.world\.item\.ArmorItem;\r?\n', ''
                $text = $text -replace 'extends\s+ArmorItem\b', 'extends Item'
                if ($text -notmatch 'import\s+net\.minecraft\.world\.item\.Item;') {
                    $text = [regex]::Replace($text, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.item.Item;${nl}", 1)
                }
                $text = $text -replace 'super\(\s*ARMOR_MATERIAL\s*,\s*type\s*,\s*properties\s*\)', 'super(properties.humanoidArmor(ARMOR_MATERIAL, type))'
            }
            if ($text -match 'extends\s+SwordItem\b') {
                $text = $text -replace 'import\s+net\.minecraft\.world\.item\.SwordItem;\r?\n', ''
                $text = $text -replace 'extends\s+SwordItem\b', 'extends Item'
                if ($text -notmatch 'import\s+net\.minecraft\.world\.item\.Item;') {
                    $text = [regex]::Replace($text, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.item.Item;${nl}", 1)
                }
                $text = $text -replace 'super\(\s*TOOL_MATERIAL\s*,\s*([0-9.F]+)\s*,\s*([-0-9.F]+)\s*,\s*properties\s*\)', 'super(properties.sword(TOOL_MATERIAL, $1, $2))'
            }
            # Block.appendHoverText removed in later 1.21.x; drop MCreator block tooltip overrides
            if ($text -match 'extends\s+\w*Block\b' -and $text -match 'void\s+appendHoverText\s*\(') {
                $text = [regex]::Replace($text,
                    '(?s)(?:@OnlyIn\s*\(\s*Dist\.CLIENT\s*\)\s*)?public\s+void\s+appendHoverText\s*\(\s*ItemStack\s+\w+\s*,\s*TooltipContext\s+\w+\s*,\s*List<\s*Component\s*>\s+\w+\s*,\s*TooltipFlag\s+\w+\s*\)\s*\{(?:[^{}]|\{[^{}]*\})*\}',
                    '/* appendHoverText removed: Block tooltips moved off Block in post-1.21.4 primers */')
            }
        }

        if ($rules -contains 'removed-block-lifecycle') {
            $text = $text -replace '\.hasPostProcess\s*\(', '.emissiveRendering('
            # 26.2 emissiveRendering takes Predicate<BlockState>, not the old 3-arg form
            $text = [regex]::Replace($text, '\.emissiveRendering\s*\(\s*\(\s*(\w+)\s*,\s*\w+\s*,\s*\w+\s*\)\s*->', '.emissiveRendering(($1) ->')
            $text = [regex]::Replace($text,
                'public\s+void\s+onRemove\s*\(\s*BlockState\s+(\w+)\s*,\s*Level\s+(\w+)\s*,\s*BlockPos\s+(\w+)\s*,\s*BlockState\s+\w+\s*,\s*boolean\s+(\w+)\s*\)',
                'protected void affectNeighborsAfterRemoval(BlockState $1, ServerLevel $2, BlockPos $3, boolean $4)')
            $text = [regex]::Replace($text,
                'super\.onRemove\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*\w+\s*,\s*(\w+)\s*\)',
                'super.affectNeighborsAfterRemoval($1, $2, $3, $4)')
            $text = $text -replace 'if\s*\(\s*(\w+)\.getBlock\(\)\s*!=\s*newState\.getBlock\(\)\s*\)', 'if (true /* was state.getBlock() != newState.getBlock(); newState removed in affectNeighborsAfterRemoval */)'

            $text = [regex]::Replace($text,
                'public\s+void\s+entityInside\s*\(\s*BlockState\s+(\w+)\s*,\s*Level\s+(\w+)\s*,\s*BlockPos\s+(\w+)\s*,\s*Entity\s+(\w+)\s*\)',
                'public void entityInside(BlockState $1, Level $2, BlockPos $3, Entity $4, net.minecraft.world.entity.InsideBlockEffectApplier effectApplier, boolean isPrecise)')
            $text = [regex]::Replace($text,
                'super\.entityInside\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)',
                'super.entityInside($1, $2, $3, $4, effectApplier, isPrecise)')

            $text = [regex]::Replace($text,
                'public\s+boolean\s+onDestroyedByPlayer\s*\(\s*BlockState\s+(\w+)\s*,\s*Level\s+(\w+)\s*,\s*BlockPos\s+(\w+)\s*,\s*Player\s+(\w+)\s*,\s*boolean\s+(\w+)\s*,\s*FluidState\s+(\w+)\s*\)',
                'public boolean onDestroyedByPlayer(BlockState $1, Level $2, BlockPos $3, Player $4, ItemStack toolStack, boolean $5, FluidState $6)')
            $text = [regex]::Replace($text,
                'super\.onDestroyedByPlayer\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)',
                'super.onDestroyedByPlayer($1, $2, $3, $4, toolStack, $5, $6)')
            if ($text -match 'onDestroyedByPlayer\s*\(' -and $text -notmatch 'import\s+net\.minecraft\.world\.item\.ItemStack;') {
                $text = [regex]::Replace($text, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.item.ItemStack;${nl}", 1)
            }
            if ($text -match 'affectNeighborsAfterRemoval\s*\(' -and $text -notmatch 'import\s+net\.minecraft\.server\.level\.ServerLevel;') {
                $text = [regex]::Replace($text, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.server.level.ServerLevel;${nl}", 1)
            }
        }

        if ($rules -contains 'block-entity-value-io') {
            if ($text -match 'void\s+loadAdditional\s*\(\s*CompoundTag\b' -or $text -match 'void\s+saveAdditional\s*\(\s*CompoundTag\b') {
                $text = $text -replace 'import\s+net\.minecraft\.core\.HolderLookup\.Provider;', ("import net.minecraft.world.level.storage.ValueInput;" + $nl + "import net.minecraft.world.level.storage.ValueOutput;")
                if ($text -notmatch 'import\s+net\.minecraft\.world\.level\.storage\.ValueInput;') {
                    $text = [regex]::Replace($text, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.level.storage.ValueInput;${nl}import net.minecraft.world.level.storage.ValueOutput;${nl}", 1)
                }
                $text = [regex]::Replace($text,
                    'public\s+void\s+loadAdditional\s*\(\s*CompoundTag\s+(\w+)\s*,\s*(?:Provider|HolderLookup\.Provider)\s+\w+\s*\)',
                    'protected void loadAdditional(ValueInput $1)')
                $text = [regex]::Replace($text,
                    'public\s+void\s+saveAdditional\s*\(\s*CompoundTag\s+(\w+)\s*,\s*(?:Provider|HolderLookup\.Provider)\s+\w+\s*\)',
                    'protected void saveAdditional(ValueOutput $1)')
                $text = $text -replace 'super\.loadAdditional\s*\(\s*(\w+)\s*,\s*\w+\s*\)', 'super.loadAdditional($1)'
                $text = $text -replace 'super\.saveAdditional\s*\(\s*(\w+)\s*,\s*\w+\s*\)', 'super.saveAdditional($1)'
                $text = $text -replace 'ContainerHelper\.loadAllItems\s*\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*\w+\s*\)', 'ContainerHelper.loadAllItems($1, $2)'
                $text = $text -replace 'ContainerHelper\.saveAllItems\s*\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*\w+\s*\)', 'ContainerHelper.saveAllItems($1, $2)'
                $text = $text -replace 'tryLoadLootTable\s*\(\s*(\w+)\s*\)', 'tryLoadLootTable($1)'
                $text = $text -replace 'trySaveLootTable\s*\(\s*(\w+)\s*\)', 'trySaveLootTable($1)'
                # getUpdateTag still uses HolderLookup.Provider in 26.2; restore import if stripped
                if ($text -match 'getUpdateTag\s*\(\s*Provider\b' -and $text -notmatch 'import\s+net\.minecraft\.core\.HolderLookup\.Provider;') {
                    $text = [regex]::Replace($text, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.core.HolderLookup.Provider;${nl}", 1)
                }
            }
        }

        if ($rules -contains 'texture-sheet-to-single-quad') {
            if ($text -match 'TextureSheetParticle') {
                $text = $text.Replace('import net.minecraft.client.particle.TextureSheetParticle;', "import net.minecraft.client.particle.SingleQuadParticle;${nl}import net.minecraft.util.RandomSource;")
                $text = $text.Replace('extends TextureSheetParticle', 'extends SingleQuadParticle')
                $text = $text -replace 'super\(\s*world\s*,\s*x\s*,\s*y\s*,\s*z\s*\)\s*;', 'super(world, x, y, z, spriteSet.first());'
                $text = $text -replace '\s*this\.pickSprite\s*\(\s*spriteSet\s*\)\s*;', ''
                $text = [regex]::Replace($text,
                    'public\s+ParticleRenderType\s+getRenderType\s*\(\s*\)\s*\{\s*return\s+ParticleRenderType\.PARTICLE_SHEET_TRANSLUCENT\s*;\s*\}',
                    "public SingleQuadParticle.Layer getLayer() {${nl}      return SingleQuadParticle.Layer.TRANSLUCENT;${nl}   }")
                $text = [regex]::Replace($text,
                    'public\s+ParticleRenderType\s+getRenderType\s*\(\s*\)\s*\{\s*return\s+ParticleRenderType\.PARTICLE_SHEET_OPAQUE\s*;\s*\}',
                    "public SingleQuadParticle.Layer getLayer() {${nl}      return SingleQuadParticle.Layer.OPAQUE;${nl}   }")
                if ($text -notmatch 'ParticleRenderType\.') {
                    $text = $text -replace 'import\s+net\.minecraft\.client\.particle\.ParticleRenderType;\r?\n', ''
                }
                $text = $text -replace 'public\s+Particle\s+createParticle\s*\(\s*SimpleParticleType\s+(\w+)\s*,\s*ClientLevel\s+(\w+)\s*,\s*double\s+(\w+)\s*,\s*double\s+(\w+)\s*,\s*double\s+(\w+)\s*,\s*double\s+(\w+)\s*,\s*double\s+(\w+)\s*,\s*double\s+(\w+)\s*\)',
                    'public Particle createParticle(SimpleParticleType $1, ClientLevel $2, double $3, double $4, double $5, double $6, double $7, double $8, RandomSource random)'
            }
        }

        if ($rules -contains 'game-rules-rewrite') {
            $text = $text.Replace('import net.minecraft.world.level.GameRules;', 'import net.minecraft.world.level.gamerules.GameRules;')
            $text = $text.Replace('import net.minecraft.world.level.GameRules.BooleanValue;', 'import net.minecraft.world.level.gamerules.GameRules.BooleanValue;')
            $text = $text.Replace('import net.minecraft.world.level.GameRules.IntegerValue;', 'import net.minecraft.world.level.gamerules.GameRules.IntegerValue;')
            $text = $text.Replace('import net.minecraft.world.level.GameRules.Category;', 'import net.minecraft.world.level.gamerules.GameRules.Category;')
            $text = $text.Replace('import net.minecraft.world.level.GameRules.Key;', 'import net.minecraft.world.level.gamerules.GameRules.Key;')
            $text = $text -replace 'net\.minecraft\.world\.level\.GameRules\.(BooleanValue|IntegerValue|Category|Key)\b', 'net.minecraft.world.level.gamerules.GameRules.$1'
            if ($text -match '\bGameRules\b' -and $text -notmatch 'import\s+net\.minecraft\.world\.level\.gamerules\.GameRules\s*;') {
                $text = [regex]::Replace($text, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.level.gamerules.GameRules;${nl}", 1)
            }
            $text = $text.Replace('GameRules.RULE_DOBLOCKDROPS', 'GameRules.BLOCK_DROPS')
            $text = $text.Replace('GameRules.RULE_DOMOBLOOT', 'GameRules.MOB_DROPS')
            $text = $text.Replace('GameRules.RULE_DOENTITYDROPS', 'GameRules.ENTITY_DROPS')
            $text = $text.Replace('GameRules.RULE_KEEPINVENTORY', 'GameRules.KEEP_INVENTORY')
            $text = $text.Replace('GameRules.RULE_MOBGRIEFING', 'GameRules.MOB_GRIEFING')
            $text = $text.Replace('GameRules.RULE_DAYLIGHT', 'GameRules.ADVANCE_TIME')
            $text = $text.Replace('GameRules.RULE_WEATHER_CYCLE', 'GameRules.ADVANCE_WEATHER')
            $text = $text.Replace('GameRules.RULE_DOFIRETICK', 'GameRules.FIRE_SPREAD_RADIUS_AROUND_PLAYER')
            $text = $text -replace 'getGameRules\(\)\.getBoolean\s*\(', 'getGameRules().get('
        }

        if ($rules -contains 'tristate-minecraft-util') {
            $text = $text.Replace('import net.neoforged.neoforge.common.util.TriState;', 'import net.minecraft.util.TriState;')
        }

        if ($rules -contains 'projectile-arrow-package') {
            $text = $text.Replace('import net.minecraft.world.entity.projectile.Arrow;', 'import net.minecraft.world.entity.projectile.arrow.Arrow;')
            $text = $text.Replace('import net.minecraft.world.entity.projectile.SpectralArrow;', 'import net.minecraft.world.entity.projectile.arrow.SpectralArrow;')
            $text = $text.Replace('import net.minecraft.world.entity.projectile.ThrownTrident;', 'import net.minecraft.world.entity.projectile.arrow.ThrownTrident;')
            $text = $text.Replace('import net.minecraft.world.entity.projectile.AbstractArrow;', 'import net.minecraft.world.entity.projectile.arrow.AbstractArrow;')
        }

        if ($text -ne $original) {
            [IO.File]::WriteAllText($file.FullName, $text)
            $touched++
        }
    }

    if ($rules -contains 'legacy-datagen-isolation') {
        $legacyDatagen = Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue |
            Select-String -Pattern 'client\.model\.generators|ExistingFileHelper|IConditionBuilder' -Quiet
        $gradlePath = Join-Path $Root 'build.gradle'
        if ($legacyDatagen -and (Test-Path -LiteralPath $gradlePath)) {
            $gradle = [IO.File]::ReadAllText($gradlePath)
            if ($gradle -notmatch "exclude '\*\*/datagen/\*\*'") {
                $gradle += "`r`n// 1.21.x datagen output is already present in resources; its generator API was removed.`r`nsourceSets.main.java {`r`n    exclude '**/datagen/**'`r`n    exclude '**/*DataGenerators.java'`r`n}`r`n"
                [IO.File]::WriteAllText($gradlePath, $gradle)
                $touched++
            }
        }
    }

    return [pscustomobject]@{ Touched=$touched; Rules=$rules; Overlays=@() }
}

function Invoke-NeoForge26ApiRewritePass {
    <#
    .SYNOPSIS
      Second-pass Minecraft/NeoForge 26.2 API renames proven on Friend-26.2 and The Knocker.
      Safe mechanical transforms only - does not invent gameplay logic.
    #>
    param([string]$Root)

    $files = Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue
    $touched = 0
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        $o = $t

        # --- NBT 26.x ---
        # getList(key, type) / getListOrEmpty(key, type) -> single-arg list accessors
        $t = $t -replace '\.getListOrEmpty\(([^,]+),\s*Tag\.[A-Z_]+\)', '.getListOrEmpty($1)'
        $t = $t -replace '\.getList\(([^,]+),\s*Tag\.[A-Z_]+\)', '.getListOrEmpty($1)'
        # Prefer OrEmpty compound accessors (Optional-based getCompound in 26.x)
        # Negative lookahead avoids rewriting getCompoundOrEmpty itself
        $t = $t -replace '\.getCompound(?!OrEmpty)\(([^)]+)\)', '.getCompoundOrEmpty($1)'
        # CompoundTag Optional accessors (getBoolean/getString return Optional in 26.2)
        $t = $t -replace '\.getPersistentData\(\)\.getBoolean\(([^)]+)\)', '.getPersistentData().getBooleanOr($1, false)'
        $t = $t -replace '\.getPersistentData\(\)\.getString\(([^)]+)\)', '.getPersistentData().getStringOr($1, "")'
        $t = $t -replace '\.getPersistentData\(\)\.getInt\(([^)]+)\)', '.getPersistentData().getIntOr($1, 0)'
        $t = $t -replace '\.getPersistentData\(\)\.getDouble\(([^)]+)\)', '.getPersistentData().getDoubleOr($1, 0.0)'
        # BlockEntity.loadWithComponents(CompoundTag, RegistryAccess) -> ValueInput
        if ($t -match '\.loadWithComponents\s*\(\s*\w+\s*,') {
            $t = [regex]::Replace($t,
                '\.loadWithComponents\s*\(\s*(\w+)\s*,\s*([^)]+?)\.registryAccess\(\)\s*\)',
                '.loadWithComponents(TagValueInput.create(ProblemReporter.DISCARDING, $2.registryAccess(), $1))')
            if ($t -match '\bTagValueInput\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.level\.storage\.TagValueInput\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                    "`$1`r`nimport net.minecraft.util.ProblemReporter;`r`nimport net.minecraft.world.level.storage.TagValueInput;`r`n", 1)
            }
            elseif ($t -match '\bProblemReporter\b' -and $t -notmatch 'import\s+net\.minecraft\.util\.ProblemReporter\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                    "`$1`r`nimport net.minecraft.util.ProblemReporter;`r`n", 1)
            }
        }

        # --- BlockState ---
        $t = $t -replace '\.isSolidRender\([^)]*\)', '.isSolidRender()'

        # --- PathNavigation: NEVER rename navigation.moveTo to snapTo ---
        # Entity absolute placement often becomes snapTo; only convert bare entity moveTo with 5 args (x,y,z,yaw,pitch)
        $t = [regex]::Replace($t,
            '(?<!getNavigation\(\)\.)(?<!Navigation\.)\bmoveTo\((\s*[^,]+,\s*[^,]+,\s*[^,]+,\s*[^,]+,\s*[^)]+)\)',
            'snapTo($1)')
        # If a prior pass wrongly converted navigation to snapTo, restore
        $t = $t -replace '\.getNavigation\(\)\.snapTo\(', '.getNavigation().moveTo('

        # --- EntityType.create needs spawn reason ---
        $t = $t -replace '\.create\((\s*(?:level|serverLevel|world)\s*)\)',
            '.create($1, net.minecraft.world.entity.EntitySpawnReason.MOB_SUMMONED)'

        # --- Server access: use level().getServer() (Entity.getServer is gone / private in places) ---
        # Do NOT touch net.minecraft.server.* imports/packages
        $t = $t -replace '(?<![\w.])(player|serverPlayer|owner|self|_player|_ent|entity|_entity|living|sourceentity|immediatesourceentity)\.server\.', '$1.level().getServer().'
        $t = $t -replace '(?<![\w.])(player|serverPlayer|owner|self|_player|_ent|entity|_entity|living|sourceentity|immediatesourceentity)\.getServer\(\)', '$1.level().getServer()'

        # --- Spawn / respawn (LevelData + ServerPlayer.RespawnConfig shape in 26.2) ---
        $t = $t -replace '\.getSharedSpawnPos\(\)', '.getRespawnData().pos()'
        $t = $t -replace '\.getLevelData\(\)\.getSpawnPos\(\)', '.getLevelData().getRespawnData().pos()'
        $t = $t -replace '\.getRespawnConfig\(\)\.pos\(\)', '.getRespawnConfig().respawnData().pos()'
        $t = $t -replace '\.getRespawnConfig\(\)\.dimension\(\)', '.getRespawnConfig().respawnData().dimension()'
        # Player respawn: prefer RespawnConfig when present (manual polish often still needed)
        $t = $t -replace '(\w+)\.getRespawnPosition\(\)',
            '($1.getRespawnConfig() != null ? $1.getRespawnConfig().respawnData().pos() : null)'

        # --- Player chat / actionbar (displayClientMessage removed; nested Component.literal args) ---
        $t = Convert-DisplayClientMessageCalls -Text $t
        $t = $t -replace '\.displayClientMessage\(([^,]+)\s*,\s*(?:true|false)\s*\)', '.sendSystemMessage($1)'

        # --- FML dist accessor ---
        $t = $t -replace 'FMLEnvironment\.dist\b', 'FMLEnvironment.getDist()'

        # --- DeferredRegister items: registerItem(name, fn, new Properties()) no longer matches ---
        $t = $t -replace '\.registerItem\(([^,]+),\s*([^,]+),\s*new\s+(?:Item\.)?Properties\(\)\s*\)', '.registerItem($1, $2)'

        # --- SpawnEggItem(EntityType, Properties) -> Properties + ENTITY_DATA component (26.x) ---
        $t = [regex]::Replace($t,
            'new\s+SpawnEggItem\(\s*(\([^)]*EntityType[^)]*\)[^,]+|\w+(?:\.\w+)*(?:\(\))?)\s*,\s*([A-Za-z_][\w]*)\s*\)',
            'new SpawnEggItem($2.component(net.minecraft.core.component.DataComponents.ENTITY_DATA, net.minecraft.world.item.component.TypedEntityData.of($1, new net.minecraft.nbt.CompoundTag())))')

        # --- CommandSourceStack permission int -> LevelBasedPermissionSet ---
        # MCreator lambdas rename locals (_level, _levelx, _levelxxxxxx, ...); match _level\w*
        $t = $t -replace '(_level\w*|_serverLevel\w*|serverLevel|level)\s*,\s*4\s*,',
            '$1, net.minecraft.server.permissions.LevelBasedPermissionSet.OWNER,'
        $t = $t -replace '(_level\w*|_serverLevel\w*|serverLevel|level)\s*,\s*2\s*,',
            '$1, net.minecraft.server.permissions.LevelBasedPermissionSet.GAMEMASTER,'
        $t = $t -replace '(_level\w*|_serverLevel\w*|serverLevel|level)\s*,\s*3\s*,',
            '$1, net.minecraft.server.permissions.LevelBasedPermissionSet.ADMIN,'
        $t = $t -replace '(\?\s*\(ServerLevel\)[^,]+?\s*:\s*null)\s*,\s*4\s*,',
            '$1, net.minecraft.server.permissions.LevelBasedPermissionSet.OWNER,'
        $t = $t -replace '(\?\s*\(ServerLevel\)[^,]+?\s*:\s*null)\s*,\s*2\s*,',
            '$1, net.minecraft.server.permissions.LevelBasedPermissionSet.GAMEMASTER,'

        # --- Client render package moves (common humanoid / glow layers) ---
        $t = $t -replace 'import\s+net\.minecraft\.client\.renderer\.MultiBufferSource\s*;',
            'import net.minecraft.client.renderer.SubmitNodeCollector;'
        $t = $t -replace 'import\s+net\.minecraft\.client\.renderer\.RenderType\s*;',
            'import net.minecraft.client.renderer.rendertype.RenderTypes;'
        # Only rewrite classic RenderType static factories; leave other RenderType mentions.
        $t = $t -replace '\bRenderType\.(eyes|entityCutout|entityCutoutNoCull|entityTranslucent|entityTranslucentEmissive)\b', 'RenderTypes.$1'
        $t = $t -replace '\bMultiBufferSource\b', 'SubmitNodeCollector'
        # Armor layer: dual bakeLayer(INNER/OUTER) -> ArmorModelSet.bake (do NOT rename INNER/OUTER tokens;
        # PLAYER_ARMOR is ArmorModelSet, not a ModelLayerLocation, so bakeLayer(PLAYER_ARMOR) does not compile).
        $t = [regex]::Replace($t,
            'new\s+HumanoidArmorLayer(?:<>)?\s*\(\s*this\s*,\s*new\s+HumanoidModel(?:<>)?\s*\(\s*context\.bakeLayer\(\s*ModelLayers\.PLAYER_INNER_ARMOR\s*\)\s*\)\s*,\s*new\s+HumanoidModel(?:<>)?\s*\(\s*context\.bakeLayer\(\s*ModelLayers\.PLAYER_OUTER_ARMOR\s*\)\s*\)\s*,\s*context\.getEquipmentRenderer\(\)\s*\)',
            'new HumanoidArmorLayer(this, net.minecraft.client.renderer.entity.ArmorModelSet.bake(ModelLayers.PLAYER_ARMOR, context.getModelSet(), HumanoidModel::new), context.getEquipmentRenderer())',
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
        # MCreator glow overlay: RenderLayer.render(PoseStack, SubmitNodeCollector, ...) is submit in 26.2
        $t = [regex]::Replace($t,
            'public\s+void\s+render\s*\(\s*PoseStack\s+(\w+)\s*,\s*SubmitNodeCollector\s+',
            'public void submit(PoseStack $1, SubmitNodeCollector ')
        # getBuffer(eyes)+renderToBuffer (plain or inside if) -> submitModel
        $t = [regex]::Replace($t,
            'VertexConsumer\s+\w+\s*=\s*(\w+)\.getBuffer\(\s*RenderTypes\.eyes\(([^;]+?)\)\s*\)\s*;\s*(?:\(\(HumanoidModel\)this\.getParentModel\(\)\)|this\.getParentModel\(\))\s*\.renderToBuffer\(\s*(\w+)\s*,\s*\w+\s*,\s*(\w+)\s*,\s*LivingEntityRenderer\.getOverlayCoords\((\w+)\s*,\s*[^)]+\)\s*\)\s*;',
            '$1.order(0).submitModel(this.getParentModel(), $5, $3, RenderTypes.eyes($2), $4, LivingEntityRenderer.getOverlayCoords($5, 0.0F), -1, null, $5.outlineColor, null);')
        # PlayerSkin.texture() -> body().texturePath()
        $t = $t -replace '\.getSkin\(\)\.texture\(\)', '.getSkin().body().texturePath()'

        # --- Legacy NeoForge item capability API (transfer rewrite is manual) ---
        # Comment out whole registerBlockEntity(ItemHandler.BLOCK, ...) calls, including Vineflower
        # multiline forms. A single-line-only replace left orphan ");" and broke compile (Easy Mob Farm).
        $t = $t -replace 'import\s+net\.neoforged\.neoforge\.capabilities\.Capabilities\.ItemHandler\s*;\s*', ''
        $t = [regex]::Replace($t,
            '(?ms)^(\s*)event\.registerBlockEntity\s*\(\s*ItemHandler\.BLOCK\s*,.*?\);',
            '$1// TODO 26.2: item handler capability moved to Capabilities.Item + transfer API (registerBlockEntity removed by converter)')
        $t = [regex]::Replace($t,
            '(?ms)^(\s*)event\.registerBlockEntity\s*\(\s*/\*\s*ItemHandler\.BLOCK removed\s*\*/\s*null\s*,.*?\);',
            '$1// TODO 26.2: item handler capability moved to Capabilities.Item + transfer API (registerBlockEntity removed by converter)')
        # Orphan closers left when only the ItemHandler.BLOCK token line was stubbed.
        $t = [regex]::Replace($t,
            '(?m)^(\s*)// TODO 26\.2: item handler capability moved to Capabilities\.Item \+ transfer API \(registerBlockEntity removed by converter\)\s*\r?\n(?:\s*// TODO 26\.2: item handler capability moved to Capabilities\.Item \+ transfer API \(registerBlockEntity removed by converter\)\s*\r?\n)*\s*\);\s*$',
            '$1// TODO 26.2: item handler capability moved to Capabilities.Item + transfer API (registerBlockEntity removed by converter)')

        # --- Effects / entity packages ---
        $t = $t -replace 'MobEffects\.MOVEMENT_SPEED', 'MobEffects.SPEED'
        $t = $t -replace 'net\.minecraft\.world\.entity\.monster\.Zombie\b',
            'net.minecraft.world.entity.monster.zombie.Zombie'
        $t = $t -replace 'net\.minecraft\.world\.entity\.animal\.Cat\b',
            'net.minecraft.world.entity.animal.feline.Cat'
        $t = $t -replace 'net\.minecraft\.world\.entity\.animal\.Wolf\b',
            'net.minecraft.world.entity.animal.wolf.Wolf'

        # --- NeoForge break event package (26.2) ---
        $t = $t -replace 'net\.neoforged\.neoforge\.event\.level\.BlockEvent\.BreakEvent',
            'net.neoforged.neoforge.event.level.block.BreakBlockEvent'
        $t = $t -replace '\bBlockEvent\.BreakEvent\b', 'BreakBlockEvent'
        # Ensure import when BreakBlockEvent is used without FQN
        if ($t -match '\bBreakBlockEvent\b' -and $t -notmatch 'import\s+net\.neoforged\.neoforge\.event\.level\.block\.BreakBlockEvent') {
            if ($t -match 'import\s+net\.neoforged\.neoforge\.event\.level\.BlockEvent;') {
                $t = $t -replace 'import\s+net\.neoforged\.neoforge\.event\.level\.BlockEvent;',
                    "import net.neoforged.neoforge.event.level.BlockEvent;`r`nimport net.neoforged.neoforge.event.level.block.BreakBlockEvent;"
            }
            elseif ($t -match '(?m)^package\s+[^;]+;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                    "`$1`r`nimport net.neoforged.neoforge.event.level.block.BreakBlockEvent;`r`n", 1)
            }
        }

        # --- Commands: hasPermission(int) -> PermissionSet ---
        $t = $t -replace '\.hasPermission\(\s*2\s*\)',
            '.permissions().hasPermission(net.minecraft.server.permissions.Permissions.COMMANDS_GAMEMASTER)'
        $t = $t -replace '\.hasPermission\(\s*4\s*\)',
            '.permissions().hasPermission(net.minecraft.server.permissions.Permissions.COMMANDS_OWNER)'
        $t = $t -replace '\.hasPermission\(\s*3\s*\)',
            '.permissions().hasPermission(net.minecraft.server.permissions.Permissions.COMMANDS_ADMIN)'

        # --- ResourceKey: dimension().location() -> identifier() ---
        $t = $t -replace '\.dimension\(\)\.location\(\)', '.dimension().identifier()'

        # --- Camera only (avoid rewriting unrelated getPosition) ---
        $t = $t -replace '\bcamera\.getPosition\(\)', 'camera.position()'
        $t = $t -replace '\bevent\.getCamera\(\)\.getPosition\(\)', 'event.getCamera().position()'

        # --- DeferredHolder single type param (SoundEvent etc.) ---
        $t = $t -replace 'DeferredHolder<\s*SoundEvent\s*>(?!\s*,)', 'DeferredHolder<SoundEvent, SoundEvent>'

        # --- ClipContext null entity ambiguity ---
        $t = $t -replace 'ClipContext\.Fluid\.NONE\s*,\s*null\)',
            'ClipContext.Fluid.NONE, net.minecraft.world.phys.shapes.CollisionContext.empty())'

        # --- EntityType.VANILLA_FIELD => EntityTypes (registry objects moved in 26.2) ---
        $tEntity = [regex]::Replace($t, '\bEntityType\.([A-Z][A-Z0-9_]*)\b', 'EntityTypes.$1')
        if ($tEntity -ne $t) {
            $t = $tEntity
            if ($t -notmatch 'import\s+net\.minecraft\.world\.entity\.EntityTypes;') {
                if ($t -match 'import\s+net\.minecraft\.world\.entity\.EntityType;') {
                    $t = $t -replace 'import\s+net\.minecraft\.world\.entity\.EntityType;',
                        "import net.minecraft.world.entity.EntityType;`r`nimport net.minecraft.world.entity.EntityTypes;"
                }
                elseif ($t -match '(?m)^package\s+[^;]+;') {
                    $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                        "`$1`r`nimport net.minecraft.world.entity.EntityTypes;`r`n", 1)
                }
            }
        }

        # --- Camera / buffers accessors ---
        $t = $t -replace '\.getMainCamera\(\)', '.mainCamera()'
        $t = [regex]::Replace(
            $t,
            'Minecraft\.getInstance\(\)\.renderBuffers\(\)',
            'Minecraft.getInstance().gameRenderer.renderBuffers()'
        )
        $t = $t -replace 'Minecraft\.getInstance\(\)\.gameRenderer\.gameRenderer\.renderBuffers\(\)',
            'Minecraft.getInstance().gameRenderer.renderBuffers()'

        # --- Colored Items/Blocks (ColorCollection) ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â full dye grid ---
        $t = Convert-ColorCollectionConstants $t

        # --- Weather / day-time (best-effort; many dims fix time in data) ---
        $t = $t -replace '(\w+)\.setWeatherParameters\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*false\s*,\s*false\s*\)',
            '{ var __w = $1.getWeatherData(); __w.setClearWeatherTime((int)($2)); __w.setRainTime(0); __w.setThunderTime(0); __w.setRaining(false); __w.setThundering(false); }'
        $t = $t -replace '(\w+)\.setWeatherParameters\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*true\s*,\s*true\s*\)',
            '{ var __w = $1.getWeatherData(); __w.setClearWeatherTime(0); __w.setRainTime((int)($3)); __w.setThunderTime((int)($3)); __w.setRaining(true); __w.setThundering(true); }'
        $t = $t -replace '(\w+)\.setDayTime\((\d+L|[\w.]+)\)',
            '$1.dimensionType().defaultClock().ifPresent(__clock -> $1.clockManager().setTotalTicks(__clock, $2))'

        # --- Teleport cross-dimension 6-arg (level, x,y,z, yaw, pitch) ---
        # Avoid nested-paren receivers; only simple identifier first arg (level/world vars)
        $t = [regex]::Replace($t,
            '(\w+)\.teleportTo\(\s*([A-Za-z_][\w]*)\s*,\s*([^,]+)\s*,\s*([^,]+)\s*,\s*([^,]+)\s*,\s*([^,]+)\s*,\s*([^)]+)\)',
            {
                param($m)
                $recv = $m.Groups[1].Value
                $a1 = $m.Groups[2].Value
                $a2 = $m.Groups[3].Value.Trim()
                $a3 = $m.Groups[4].Value.Trim()
                $a4 = $m.Groups[5].Value.Trim()
                $a5 = $m.Groups[6].Value.Trim()
                $a6 = $m.Groups[7].Value.Trim()
                if ($a5 -match 'emptySet|Relative|Set\.') { return $m.Value }
                if ($a6 -match '^\s*(true|false)\s*$' -and $a5 -match 'emptySet|Set\.') { return $m.Value }
                # skip same-dimension 3-double style misparse (first arg looks numeric via var unlikely)
                if ($a1 -match '^(?i)(x|y|z|dx|dy|dz)$') { return $m.Value }
                "$recv.teleportTo($a1, $a2, $a3, $a4, java.util.Collections.emptySet(), $a5, $a6, true)"
            })

        # --- Advancement lookup ---
        $t = $t -replace '\.getAdvancements\(\)\.getAdvancement\(', '.getAdvancements().get('

        # --- Hand-written NeoForge 1.21.x -> 26.2 (MedSystem / TarkovCraft lessons) ---
        # Item use animation enum rename
        $t = $t -replace '\bUseAnim\b', 'ItemUseAnimation'
        $t = $t -replace 'import\s+net\.minecraft\.world\.item\.ItemUseAnimation;', 'import net.minecraft.world.item.ItemUseAnimation;'
        $t = $t -replace 'import\s+net\.minecraft\.world\.item\.UseAnim;', 'import net.minecraft.world.item.ItemUseAnimation;'

        # InteractionResultHolder<ItemStack> use(...) -> InteractionResult use(...)
        $t = [regex]::Replace($t,
            'public\s+(?:final\s+)?InteractionResultHolder\s*<\s*ItemStack\s*>\s+use\s*\(',
            'public final InteractionResult use(')
        $t = $t -replace 'InteractionResultHolder\.success\([^)]*\)', 'InteractionResult.SUCCESS'
        $t = $t -replace 'InteractionResultHolder\.fail\([^)]*\)', 'InteractionResult.FAIL'
        $t = $t -replace 'InteractionResultHolder\.pass\([^)]*\)', 'InteractionResult.PASS'
        $t = $t -replace 'InteractionResultHolder\.consume\([^)]*\)', 'InteractionResult.CONSUME'
        # Common leftover: switch wrapping InteractionResult back into InteractionResultHolder
        $t = [regex]::Replace($t,
            '(?ms)return\s+switch\s*\(\s*result\s*\)\s*\{\s*case\s+CONSUME,\s*CONSUME_PARTIAL\s*->\s*InteractionResult\.CONSUME\s*;\s*case\s+SUCCESS,\s*SUCCESS_NO_ITEM_USED\s*->\s*InteractionResult\.SUCCESS\s*;\s*case\s+FAIL\s*->\s*InteractionResult\.FAIL\s*;\s*case\s+PASS\s*->\s*InteractionResult\.PASS\s*;\s*default\s*->\s*throw\s+new\s+MatchException\([^;]*;\s*\}\s*;',
            'return result;')
        $t = $t -replace 'import\s+net\.minecraft\.world\.InteractionResultHolder\s*;\r?\n', ''

        # NeoForge reload listener event rename
        $t = $t -replace '\bAddReloadListenerEvent\b', 'AddServerReloadListenersEvent'
        $t = $t -replace 'import\s+net\.neoforged\.neoforge\.event\.AddServerReloadListenersEvent;', 'import net.neoforged.neoforge.event.AddServerReloadListenersEvent;'
        $t = $t -replace 'import\s+net\.neoforged\.neoforge\.event\.AddReloadListenerEvent;', 'import net.neoforged.neoforge.event.AddServerReloadListenersEvent;'

        # LootContextParam -> ContextKey (custom context maps; loot package removed/moved)
        $t = $t -replace '\bLootContextParam\b', 'ContextKey'
        $t = $t -replace 'import\s+net\.minecraft\.world\.level\.storage\.loot\.parameters\.ContextKey;', 'import net.minecraft.util.context.ContextKey;'
        $t = $t -replace 'import\s+net\.minecraft\.world\.level\.storage\.loot\.parameters\.LootContextParam;', 'import net.minecraft.util.context.ContextKey;'
        if ($t -match '\bContextKey\b' -and $t -notmatch 'import\s+net\.minecraft\.util\.context\.ContextKey\s*;') {
            $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport net.minecraft.util.context.ContextKey;`r`n", 1)
        }

        # Advancements: critereon -> predicates / triggers packages
        $t = $t -replace 'net\.minecraft\.advancements\.critereon\.SimpleCriterionTrigger', 'net.minecraft.advancements.triggers.SimpleCriterionTrigger'
        $t = $t -replace 'net\.minecraft\.advancements\.critereon\.ContextAwarePredicate', 'net.minecraft.advancements.predicates.ContextAwarePredicate'
        $t = $t -replace 'net\.minecraft\.advancements\.critereon\.EntityPredicate', 'net.minecraft.advancements.predicates.entity.EntityPredicate'
        $t = $t -replace 'net\.minecraft\.advancements\.critereon\.DamageSourcePredicate', 'net.minecraft.advancements.predicates.DamageSourcePredicate'
        $t = $t -replace 'net\.minecraft\.advancements\.critereon\.TagPredicate', 'net.minecraft.advancements.predicates.TagPredicate'
        $t = $t -replace 'import\s+net\.minecraft\.advancements\.critereon\.SimpleCriterionTrigger\.SimpleInstance;', 'import net.minecraft.advancements.triggers.SimpleCriterionTrigger.SimpleInstance;'

        # HUD layers: LayeredDraw.Layer removed -> NeoForge GuiLayer
        $t = $t -replace 'import\s+net\.minecraft\.client\.gui\.LayeredDraw\.Layer\s*;', 'import net.neoforged.neoforge.client.gui.GuiLayer;'
        $t = $t -replace 'import\s+net\.minecraft\.client\.gui\.LayeredDraw\s*;', 'import net.neoforged.neoforge.client.gui.GuiLayer;'
        $t = $t -replace 'implements\s+LayeredDraw\.Layer\b', 'implements GuiLayer'
        $t = $t -replace 'implements\s+Layer\b(?=\s*\{)', 'implements GuiLayer'
        if ($t -match 'implements\s+GuiLayer') {
            $t = [regex]::Replace($t,
                'public\s+void\s+extractRenderState\s*\(\s*GuiGraphicsExtractor\s+',
                'public void render(GuiGraphicsExtractor ')
            if ($t -notmatch 'import\s+net\.neoforged\.neoforge\.client\.gui\.GuiLayer\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.client.gui.GuiLayer;`r`n", 1)
            }
        }

        # ARGB helper: prefer vanilla net.minecraft.util.ARGB (Core helper removed in 26.2 TarkovCraft)
        $t = $t -replace 'import\s+tnt\.tarkovcraft\.core\.util\.helper\.ARGB\s*;', 'import net.minecraft.util.ARGB;'
        $t = $t -replace '\btnt\.tarkovcraft\.core\.util\.helper\.ARGB\b', 'net.minecraft.util.ARGB'

        # HeartType moved Gui -> Hud
        $t = $t -replace 'import\s+net\.minecraft\.client\.gui\.Gui\.HeartType\s*;', 'import net.minecraft.client.gui.Hud.HeartType;'
        $t = $t -replace '\bGui\.HeartType\b', 'Hud.HeartType'

        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $touched++
        }
    }
    return $touched
}

function Invoke-MinecraftEntitySubpackageRemapPass {
    <#
    .SYNOPSIS
      1.21.11 primer entity/item package remaps for NeoForge 26.2:
      animal/monster/npc subpackages, horse→equine, Util, ArmorMaterial/ArmorType,
      GameRules nested imports, and EntityRenderer one-type-arg → LivingEntityRenderState.
    #>
    param([string]$Root)

    $javaRoot = Join-Path $Root 'src\main\java'
    $nl = [Environment]::NewLine
    $touched = 0

    # Class remaps: old FQN prefix (without trailing class) handled via exact old→new FQNs
    $classRemaps = [ordered]@{
        'net.minecraft.world.entity.animal.AbstractGolem' = 'net.minecraft.world.entity.animal.golem.AbstractGolem'
        'net.minecraft.world.entity.animal.IronGolem' = 'net.minecraft.world.entity.animal.golem.IronGolem'
        'net.minecraft.world.entity.animal.SnowGolem' = 'net.minecraft.world.entity.animal.golem.SnowGolem'
        'net.minecraft.world.entity.animal.Cow' = 'net.minecraft.world.entity.animal.cow.Cow'
        'net.minecraft.world.entity.animal.AbstractCow' = 'net.minecraft.world.entity.animal.cow.AbstractCow'
        'net.minecraft.world.entity.animal.MushroomCow' = 'net.minecraft.world.entity.animal.cow.MushroomCow'
        'net.minecraft.world.entity.animal.Pig' = 'net.minecraft.world.entity.animal.pig.Pig'
        'net.minecraft.world.entity.animal.Chicken' = 'net.minecraft.world.entity.animal.chicken.Chicken'
        'net.minecraft.world.entity.animal.Rabbit' = 'net.minecraft.world.entity.animal.rabbit.Rabbit'
        'net.minecraft.world.entity.animal.Parrot' = 'net.minecraft.world.entity.animal.parrot.Parrot'
        'net.minecraft.world.entity.animal.ShoulderRidingEntity' = 'net.minecraft.world.entity.animal.parrot.ShoulderRidingEntity'
        'net.minecraft.world.entity.animal.Sheep' = 'net.minecraft.world.entity.animal.sheep.Sheep'
        'net.minecraft.world.entity.animal.Cat' = 'net.minecraft.world.entity.animal.feline.Cat'
        'net.minecraft.world.entity.animal.Ocelot' = 'net.minecraft.world.entity.animal.feline.Ocelot'
        'net.minecraft.world.entity.animal.Bee' = 'net.minecraft.world.entity.animal.bee.Bee'
        'net.minecraft.world.entity.animal.Fox' = 'net.minecraft.world.entity.animal.fox.Fox'
        'net.minecraft.world.entity.animal.Panda' = 'net.minecraft.world.entity.animal.panda.Panda'
        'net.minecraft.world.entity.animal.PolarBear' = 'net.minecraft.world.entity.animal.polarbear.PolarBear'
        'net.minecraft.world.entity.animal.Squid' = 'net.minecraft.world.entity.animal.squid.Squid'
        'net.minecraft.world.entity.animal.GlowSquid' = 'net.minecraft.world.entity.animal.squid.GlowSquid'
        'net.minecraft.world.entity.animal.Turtle' = 'net.minecraft.world.entity.animal.turtle.Turtle'
        'net.minecraft.world.entity.animal.Dolphin' = 'net.minecraft.world.entity.animal.dolphin.Dolphin'
        'net.minecraft.world.entity.animal.WaterAnimal' = 'net.minecraft.world.entity.animal.fish.WaterAnimal'
        'net.minecraft.world.entity.animal.AbstractFish' = 'net.minecraft.world.entity.animal.fish.AbstractFish'
        'net.minecraft.world.entity.animal.Cod' = 'net.minecraft.world.entity.animal.fish.Cod'
        'net.minecraft.world.entity.animal.Salmon' = 'net.minecraft.world.entity.animal.fish.Salmon'
        'net.minecraft.world.entity.animal.Pufferfish' = 'net.minecraft.world.entity.animal.fish.Pufferfish'
        'net.minecraft.world.entity.animal.TropicalFish' = 'net.minecraft.world.entity.animal.fish.TropicalFish'
        'net.minecraft.world.entity.animal.AbstractSchoolingFish' = 'net.minecraft.world.entity.animal.fish.AbstractSchoolingFish'
        'net.minecraft.world.entity.npc.Villager' = 'net.minecraft.world.entity.npc.villager.Villager'
        'net.minecraft.world.entity.npc.AbstractVillager' = 'net.minecraft.world.entity.npc.villager.AbstractVillager'
        'net.minecraft.world.entity.npc.VillagerData' = 'net.minecraft.world.entity.npc.villager.VillagerData'
        'net.minecraft.world.entity.npc.VillagerProfession' = 'net.minecraft.world.entity.npc.villager.VillagerProfession'
        'net.minecraft.world.entity.npc.VillagerType' = 'net.minecraft.world.entity.npc.villager.VillagerType'
        'net.minecraft.world.entity.npc.VillagerDataHolder' = 'net.minecraft.world.entity.npc.villager.VillagerDataHolder'
        # VillagerTrades lives under item.trading in 26.2 (not npc.villager)
        'net.minecraft.world.entity.npc.VillagerTrades' = 'net.minecraft.world.item.trading.VillagerTrades'
        'net.minecraft.world.entity.npc.WanderingTrader' = 'net.minecraft.world.entity.npc.wanderingtrader.WanderingTrader'
        'net.minecraft.world.entity.npc.WanderingTraderSpawner' = 'net.minecraft.world.entity.npc.wanderingtrader.WanderingTraderSpawner'
        'net.minecraft.world.entity.monster.Evoker' = 'net.minecraft.world.entity.monster.illager.Evoker'
        'net.minecraft.world.entity.monster.Pillager' = 'net.minecraft.world.entity.monster.illager.Pillager'
        'net.minecraft.world.entity.monster.Vindicator' = 'net.minecraft.world.entity.monster.illager.Vindicator'
        'net.minecraft.world.entity.monster.Illusioner' = 'net.minecraft.world.entity.monster.illager.Illusioner'
        'net.minecraft.world.entity.monster.AbstractIllager' = 'net.minecraft.world.entity.monster.illager.AbstractIllager'
        'net.minecraft.world.entity.monster.SpellcasterIllager' = 'net.minecraft.world.entity.monster.illager.SpellcasterIllager'
        'net.minecraft.world.entity.monster.Zombie' = 'net.minecraft.world.entity.monster.zombie.Zombie'
        'net.minecraft.world.entity.monster.Husk' = 'net.minecraft.world.entity.monster.zombie.Husk'
        'net.minecraft.world.entity.monster.Drowned' = 'net.minecraft.world.entity.monster.zombie.Drowned'
        'net.minecraft.world.entity.monster.ZombieVillager' = 'net.minecraft.world.entity.monster.zombie.ZombieVillager'
        'net.minecraft.world.entity.monster.ZombifiedPiglin' = 'net.minecraft.world.entity.monster.zombie.ZombifiedPiglin'
        'net.minecraft.world.entity.monster.Skeleton' = 'net.minecraft.world.entity.monster.skeleton.Skeleton'
        'net.minecraft.world.entity.monster.Stray' = 'net.minecraft.world.entity.monster.skeleton.Stray'
        'net.minecraft.world.entity.monster.WitherSkeleton' = 'net.minecraft.world.entity.monster.skeleton.WitherSkeleton'
        'net.minecraft.world.entity.monster.AbstractSkeleton' = 'net.minecraft.world.entity.monster.skeleton.AbstractSkeleton'
        'net.minecraft.world.entity.monster.Bogged' = 'net.minecraft.world.entity.monster.skeleton.Bogged'
        'net.minecraft.world.entity.monster.Spider' = 'net.minecraft.world.entity.monster.spider.Spider'
        'net.minecraft.world.entity.monster.CaveSpider' = 'net.minecraft.world.entity.monster.spider.CaveSpider'
        # CASE-006 Easy Mob Farm / 1.21.11 cubemob + frog + feline variants (26.2 physical source)
        'net.minecraft.world.entity.monster.MagmaCube' = 'net.minecraft.world.entity.monster.cubemob.MagmaCube'
        'net.minecraft.world.entity.monster.Slime' = 'net.minecraft.world.entity.monster.cubemob.Slime'
        'net.minecraft.world.entity.animal.Frog' = 'net.minecraft.world.entity.animal.frog.Frog'
        'net.minecraft.world.entity.animal.FrogVariant' = 'net.minecraft.world.entity.animal.frog.FrogVariant'
        'net.minecraft.world.entity.animal.FrogVariants' = 'net.minecraft.world.entity.animal.frog.FrogVariants'
        'net.minecraft.world.entity.animal.CatVariant' = 'net.minecraft.world.entity.animal.feline.CatVariant'
        'net.minecraft.world.entity.animal.CatVariants' = 'net.minecraft.world.entity.animal.feline.CatVariants'
        # 1.21.11 vehicle subpackages (catfighting / minecart mixins)
        'net.minecraft.world.entity.vehicle.AbstractMinecart' = 'net.minecraft.world.entity.vehicle.minecart.AbstractMinecart'
        'net.minecraft.world.entity.vehicle.AbstractMinecartContainer' = 'net.minecraft.world.entity.vehicle.minecart.AbstractMinecartContainer'
        'net.minecraft.world.entity.vehicle.Minecart' = 'net.minecraft.world.entity.vehicle.minecart.Minecart'
        'net.minecraft.world.entity.vehicle.MinecartBehavior' = 'net.minecraft.world.entity.vehicle.minecart.MinecartBehavior'
        'net.minecraft.world.entity.vehicle.MinecartChest' = 'net.minecraft.world.entity.vehicle.minecart.MinecartChest'
        'net.minecraft.world.entity.vehicle.MinecartCommandBlock' = 'net.minecraft.world.entity.vehicle.minecart.MinecartCommandBlock'
        'net.minecraft.world.entity.vehicle.MinecartFurnace' = 'net.minecraft.world.entity.vehicle.minecart.MinecartFurnace'
        'net.minecraft.world.entity.vehicle.MinecartHopper' = 'net.minecraft.world.entity.vehicle.minecart.MinecartHopper'
        'net.minecraft.world.entity.vehicle.MinecartSpawner' = 'net.minecraft.world.entity.vehicle.minecart.MinecartSpawner'
        'net.minecraft.world.entity.vehicle.MinecartTNT' = 'net.minecraft.world.entity.vehicle.minecart.MinecartTNT'
        'net.minecraft.world.entity.vehicle.NewMinecartBehavior' = 'net.minecraft.world.entity.vehicle.minecart.NewMinecartBehavior'
        'net.minecraft.world.entity.vehicle.OldMinecartBehavior' = 'net.minecraft.world.entity.vehicle.minecart.OldMinecartBehavior'
        'net.minecraft.world.entity.vehicle.AbstractBoat' = 'net.minecraft.world.entity.vehicle.boat.AbstractBoat'
        'net.minecraft.world.entity.vehicle.AbstractChestBoat' = 'net.minecraft.world.entity.vehicle.boat.AbstractChestBoat'
        'net.minecraft.world.entity.vehicle.Boat' = 'net.minecraft.world.entity.vehicle.boat.Boat'
        'net.minecraft.world.entity.vehicle.ChestBoat' = 'net.minecraft.world.entity.vehicle.boat.ChestBoat'
        'net.minecraft.world.entity.vehicle.ChestRaft' = 'net.minecraft.world.entity.vehicle.boat.ChestRaft'
        'net.minecraft.world.entity.vehicle.Raft' = 'net.minecraft.world.entity.vehicle.boat.Raft'
        # Client feline model: 1.21.11 package move (intermediate). 26.1 split handled below — not 1:1.
        'net.minecraft.client.model.FelineModel' = 'net.minecraft.client.model.animal.feline.FelineModel'
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue)) {
        $t = [IO.File]::ReadAllText($file.FullName)
        $o = $t

        # Undo prior blanket GeckoLib AnimationState→AnimationTest on vanilla entity AnimationState
        if ($t -match 'import\s+net\.minecraft\.world\.entity\.AnimationTest\b' -or
            ($t -match '(?<![\w.])AnimationTest\b' -and $t -notmatch 'import\s+com\.geckolib\b' -and $t -notmatch 'import\s+software\.bernie\b' -and $t -notmatch '\bcom\.geckolib\.' -and $t -notmatch '\bsoftware\.bernie\.')) {
            $t = $t -replace 'import\s+net\.minecraft\.world\.entity\.AnimationTest\s*;', 'import net.minecraft.world.entity.AnimationState;'
            $t = $t -replace 'net\.minecraft\.world\.entity\.AnimationTest\b', 'net.minecraft.world.entity.AnimationState'
            $t = $t -replace '(?<![\w.])AnimationTest\b', 'AnimationState'
        }

        # Longest FQN first so Zombie does not eat ZombieVillager / ZombifiedPiglin, etc.
        foreach ($old in @($classRemaps.Keys | Sort-Object { $_.Length } -Descending)) {
            $new = $classRemaps[$old]
            if ($t.Contains($old)) {
                $t = $t.Replace($old, $new)
            }
            # Mixin method descriptors use JVM slash form; FQN Replace misses them.
            $oldSlash = $old.Replace('.', '/')
            $newSlash = $new.Replace('.', '/')
            if ($t.Contains($oldSlash)) {
                $t = $t.Replace($oldSlash, $newSlash)
            }
        }

        # 26.1: FelineModel split (not 1:1). createBodyMesh → AdultFelineModel; setupAnim mixins → Adult+Baby.
        if ($t -match 'client\.model\.animal\.feline\.FelineModel\b' -or $t -match '(?<![\w.])FelineModel\b') {
            $hasBodyMesh = $t -match 'createBodyMesh'
            $hasSetupAnimInject = $t -match 'setupAnim\(' -and $t -match '@Mixin'
            if ($hasBodyMesh -and -not $hasSetupAnimInject) {
                $t = $t.Replace('net.minecraft.client.model.animal.feline.FelineModel', 'net.minecraft.client.model.animal.feline.AdultFelineModel')
                $t = $t -replace '@Mixin\(\s*FelineModel\.class\s*\)', '@Mixin(AdultFelineModel.class)'
                $t = $t -replace 'import\s+net\.minecraft\.client\.model\.animal\.feline\.FelineModel\s*;', 'import net.minecraft.client.model.animal.feline.AdultFelineModel;'
            }
            elseif ($hasSetupAnimInject) {
                $t = $t -replace 'import\s+net\.minecraft\.client\.model\.animal\.feline\.FelineModel\s*;', "import net.minecraft.client.model.animal.feline.AdultFelineModel;${nl}import net.minecraft.client.model.animal.feline.BabyFelineModel;"
                $t = $t -replace '@Mixin\(\s*FelineModel\.class\s*\)', '@Mixin({AdultFelineModel.class, BabyFelineModel.class})'
                $t = $t.Replace('net.minecraft.client.model.animal.feline.FelineModel', 'net.minecraft.client.model.animal.feline.AbstractFelineModel')
            }
            else {
                $t = $t.Replace('net.minecraft.client.model.animal.feline.FelineModel', 'net.minecraft.client.model.animal.feline.AbstractFelineModel')
                $t = $t -replace 'import\s+net\.minecraft\.client\.model\.animal\.feline\.FelineModel\s*;', 'import net.minecraft.client.model.animal.feline.AbstractFelineModel;'
                $t = $t -replace '@Mixin\(\s*FelineModel\.class\s*\)', '@Mixin(AbstractFelineModel.class)'
                $t = $t -replace '(?<![\w.])FelineModel\b', 'AbstractFelineModel'
            }
        }

        # horse → equine (package + FQN)
        $t = $t.Replace('net.minecraft.world.entity.animal.horse.', 'net.minecraft.world.entity.animal.equine.')
        $t = $t.Replace('net/minecraft/world/entity/animal/horse/', 'net/minecraft/world/entity/animal/equine/')

        # Util: import + FQN (MUST be case-sensitive; -replace would turn util.Mth into util.Util.Mth)
        $t = $t -creplace 'import\s+net\.minecraft\.Util\s*;', 'import net.minecraft.util.Util;'
        $t = $t -creplace '(?<![\w.])net\.minecraft\.Util\b', 'net.minecraft.util.Util'
        # Undo ignore-case damage on sibling types only (Util.Mth / Util.RandomSource); keep Util.make
        $t = $t -creplace 'net\.minecraft\.util\.Util\.([A-Z]\w*)', 'net.minecraft.util.$1'

        # ArmorMaterial / ArmorType / Layer package moves
        $hadArmorItemType = $t -match 'import\s+net\.minecraft\.world\.item\.ArmorItem\.Type\s*;' -or $t -match 'ArmorItem\.Type\b'
        $t = $t -replace 'import\s+net\.minecraft\.world\.item\.ArmorMaterial\s*;', 'import net.minecraft.world.item.equipment.ArmorMaterial;'
        $t = $t -replace 'import\s+net\.minecraft\.world\.item\.ArmorItem\.Type\s*;', 'import net.minecraft.world.item.equipment.ArmorType;'
        $t = $t -replace 'import\s+net\.minecraft\.world\.item\.ArmorMaterial\.Layer\s*;', 'import net.minecraft.world.item.equipment.ArmorMaterial.Layer;'
        $t = [regex]::Replace($t, '(?<!net\.minecraft\.world\.item\.equipment\.)net\.minecraft\.world\.item\.ArmorMaterial\b', 'net.minecraft.world.item.equipment.ArmorMaterial')
        $t = [regex]::Replace($t, '(?<!net\.minecraft\.world\.item\.equipment\.)net\.minecraft\.world\.item\.ArmorItem\.Type\b', 'net.minecraft.world.item.equipment.ArmorType')
        if ($hadArmorItemType) {
            $t = $t -replace '(?<![\w.])ArmorItem\.Type\b', 'ArmorType'
            # Bare Type refs from former ArmorItem.Type import (MCreator armor items)
            if ($t -match 'import\s+net\.minecraft\.world\.item\.equipment\.ArmorType\s*;') {
                $t = $t -replace '(?<![\w.])Type\.(BOOTS|LEGGINGS|CHESTPLATE|HELMET|BODY)\b', 'ArmorType.$1'
                $t = $t -replace 'EnumMap\(\s*Type\.class\s*\)', 'EnumMap(ArmorType.class)'
                $t = $t -replace 'EnumMap<\s*Type\s*,', 'EnumMap<ArmorType,'
                $t = $t -replace '\(\s*Type\s+(\w+)\s*,\s*Properties\b', '(ArmorType $1, Properties'
                $t = $t -replace 'super\(\s*Type\.', 'super(ArmorType.'
            }
        }

        # GameRules nested imports (BooleanValue/Category/Key may still need later API reshape)
        $t = $t.Replace('import net.minecraft.world.level.GameRules;', 'import net.minecraft.world.level.gamerules.GameRules;')
        $t = $t.Replace('import net.minecraft.world.level.GameRules.BooleanValue;', 'import net.minecraft.world.level.gamerules.GameRules.BooleanValue;')
        $t = $t.Replace('import net.minecraft.world.level.GameRules.IntegerValue;', 'import net.minecraft.world.level.gamerules.GameRules.IntegerValue;')
        $t = $t.Replace('import net.minecraft.world.level.GameRules.Category;', 'import net.minecraft.world.level.gamerules.GameRules.Category;')
        $t = $t.Replace('import net.minecraft.world.level.GameRules.Key;', 'import net.minecraft.world.level.gamerules.GameRules.Key;')
        $t = $t -replace 'net\.minecraft\.world\.level\.GameRules\.(BooleanValue|IntegerValue|Category|Key)\b', 'net.minecraft.world.level.gamerules.GameRules.$1'
        if (($t -match '\bGameRules\.(BooleanValue|IntegerValue|Category|Key)\b' -or $t -match '\bGameRules\.register\b') -and
            $t -notmatch 'import\s+net\.minecraft\.world\.level\.gamerules\.GameRules\s*;') {
            $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.level.gamerules.GameRules;${nl}", 1)
        }

        # EntityRenderer<T> → EntityRenderer<T, LivingEntityRenderState> (exactly one type arg)
        if ($t -match 'extends\s+EntityRenderer<\s*[^,<>]+\s*>') {
            $t = [regex]::Replace($t, 'extends\s+EntityRenderer<\s*([^,<>]+?)\s*>', 'extends EntityRenderer<$1, LivingEntityRenderState>')
            if ($t -match 'LivingEntityRenderState' -and $t -notmatch 'import\s+net\.minecraft\.client\.renderer\.entity\.state\.LivingEntityRenderState\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.client.renderer.entity.state.LivingEntityRenderState;${nl}", 1)
            }
        }

        if ($t -ne $o) {
            [IO.File]::WriteAllText($file.FullName, $t)
            $touched++
        }
    }

    return $touched
}

function Invoke-Minecraft262CustomGameRuleDeferredRegister {
    <#
    .SYNOPSIS
      Custom GameRules must not call GameRules.registerBoolean/register in <clinit> or
      FMLCommonSetupEvent — BuiltInRegistries.GAME_RULE is frozen by mod construction
      (gecko_kings crash: spawnHellishXenomorphs). Match MCreator 26.1.2:
      DeferredRegister.create(Registries.GAME_RULE, MODID) + new GameRule<>() supplier,
      register REGISTRY on the mod bus, and .get() DeferredHolder at use sites.
    #>
    param([string]$Root)

    $javaRoot = Join-Path $Root 'src\main\java'
    if (-not (Test-Path -LiteralPath $javaRoot)) { return 0 }
    $nl = [Environment]::NewLine
    $touched = 0
    $converted = New-Object System.Collections.Generic.List[object]

    foreach ($file in @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue)) {
        $t = [IO.File]::ReadAllText($file.FullName)
        $cm = [regex]::Match($t, 'public\s+class\s+(\w*GameRules)\b')
        if (-not $cm.Success) { continue }
        $className = $cm.Groups[1].Value
        $pkg = [regex]::Match($t, '(?m)^package\s+([^;]+)').Groups[1].Value
        $alreadyDeferred = ($t -match 'DeferredRegister\.create\(\s*Registries\.GAME_RULE') -and ($t -match '(?m)^import\s+net\.minecraft\.core\.registries\.Registries\s*;')
        $hasCustomRegister = $t -match 'GameRules\.register(Boolean|Integer)?' -or $t -match 'BooleanValue\.create' -or $t -match 'IntegerValue\.create' -or $t -match '=\s*registerBoolean\s*\(' -or $t -match '=\s*registerInteger\s*\('
        if (-not $alreadyDeferred -and -not $hasCustomRegister) { continue }

        $ruleMap = [ordered]@{}
        foreach ($m in [regex]::Matches($t, 'GameRule<\s*Boolean\s*>\s*(?:>\s+)?([A-Z0-9_]+)\s*=\s*(?:GameRules\.)?registerBoolean\s*\(\s*"([^"]+)"\s*,\s*GameRuleCategory\.([A-Z_]+)\s*,\s*(true|false)\s*\)')) {
            if (-not $ruleMap.Contains($m.Groups[1].Value)) {
                $ruleMap[$m.Groups[1].Value] = @{ Id = $m.Groups[2].Value; Category = $m.Groups[3].Value; Kind = 'bool'; Default = $m.Groups[4].Value }
            }
        }
        foreach ($m in [regex]::Matches($t, '([A-Z0-9_]+)\s*=\s*GameRules\.register\s*\(\s*"([^"]+)"\s*,\s*(?:GameRules\.)?Category\.([A-Z_]+)\s*,\s*(?:GameRules\.)?BooleanValue\.create\s*\(\s*(true|false)\s*\)')) {
            if (-not $ruleMap.Contains($m.Groups[1].Value)) {
                $ruleMap[$m.Groups[1].Value] = @{ Id = $m.Groups[2].Value; Category = $m.Groups[3].Value; Kind = 'bool'; Default = $m.Groups[4].Value }
            }
        }
        foreach ($m in [regex]::Matches($t, 'GameRule<\s*Integer\s*>\s*(?:>\s+)?([A-Z0-9_]+)\s*=\s*(?:GameRules\.)?registerInteger\s*\(\s*"([^"]+)"\s*,\s*GameRuleCategory\.([A-Z_]+)\s*,\s*(-?\d+)')) {
            if (-not $ruleMap.Contains($m.Groups[1].Value)) {
                $ruleMap[$m.Groups[1].Value] = @{ Id = $m.Groups[2].Value; Category = $m.Groups[3].Value; Kind = 'int'; Default = $m.Groups[4].Value }
            }
        }
        foreach ($m in [regex]::Matches($t, '([A-Z0-9_]+)\s*=\s*GameRules\.register\s*\(\s*"([^"]+)"\s*,\s*(?:GameRules\.)?Category\.([A-Z_]+)\s*,\s*(?:GameRules\.)?IntegerValue\.create\s*\(\s*(-?\d+)\s*\)')) {
            if (-not $ruleMap.Contains($m.Groups[1].Value)) {
                $ruleMap[$m.Groups[1].Value] = @{ Id = $m.Groups[2].Value; Category = $m.Groups[3].Value; Kind = 'int'; Default = $m.Groups[4].Value }
            }
        }
        $deferredFields = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($t, 'DeferredHolder<\s*GameRule<\s*\?>\s*,\s*GameRule<\s*(?:Boolean|Integer)\s*>\s*>\s+([A-Z0-9_]+)')) {
            if (-not $deferredFields.Contains($m.Groups[1].Value)) { [void]$deferredFields.Add($m.Groups[1].Value) }
        }

        $javaModName = $className -replace 'GameRules$', ''
        $modidExpr = "$javaModName.MODID"
        $modJava = @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter "$javaModName.java" -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "$javaModName.java" } | Select-Object -First 1)
        $hasModClass = $modJava.Count -gt 0
        if (-not $hasModClass) {
            $modidLiteral = $null
            foreach ($mf in @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue)) {
                $mtxt = [IO.File]::ReadAllText($mf.FullName)
                $mm = [regex]::Match($mtxt, 'public\s+static\s+final\s+String\s+MODID\s*=\s*"([^"]+)"')
                if ($mm.Success) { $modidLiteral = $mm.Groups[1].Value; break }
            }
            if ($modidLiteral) { $modidExpr = '"' + $modidLiteral + '"' }
        }

        if (-not $alreadyDeferred) {
            if ($ruleMap.Count -eq 0) { continue }
            $hasBool = @($ruleMap.GetEnumerator() | Where-Object { $_.Value.Kind -eq 'bool' }).Count -gt 0
            $hasInt = @($ruleMap.GetEnumerator() | Where-Object { $_.Value.Kind -eq 'int' }).Count -gt 0
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append("package $pkg;$nl$nl")
            if ($hasBool) { [void]$sb.Append("import com.mojang.brigadier.arguments.BoolArgumentType;$nl") }
            if ($hasInt) { [void]$sb.Append("import com.mojang.brigadier.arguments.IntegerArgumentType;$nl") }
            [void]$sb.Append("import com.mojang.serialization.Codec;$nl")
            if ($hasModClass -and $modidExpr -match '\.MODID$') {
                $parentPkg = $pkg -replace '\.init$', ''
                [void]$sb.Append("import $parentPkg.$javaModName;$nl")
            }
            [void]$sb.Append(@"
import net.minecraft.core.registries.Registries;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.level.gamerules.GameRule;
import net.minecraft.world.level.gamerules.GameRuleCategory;
import net.minecraft.world.level.gamerules.GameRuleType;
import net.minecraft.world.level.gamerules.GameRuleTypeVisitor;
import net.neoforged.neoforge.registries.DeferredHolder;
import net.neoforged.neoforge.registries.DeferredRegister;

public class $className {
   public static final DeferredRegister<GameRule<?>> REGISTRY = DeferredRegister.create(Registries.GAME_RULE, $modidExpr);

"@)
            foreach ($entry in $ruleMap.GetEnumerator()) {
                $n = $entry.Key
                $r = $entry.Value
                [void]$deferredFields.Add($n)
                if ($r.Kind -eq 'int') {
                    [void]$sb.Append("   public static final DeferredHolder<GameRule<?>, GameRule<Integer>> $n = registerInteger(`"$($r.Id)`", GameRuleCategory.$($r.Category), $($r.Default));$nl")
                } else {
                    [void]$sb.Append("   public static final DeferredHolder<GameRule<?>, GameRule<Boolean>> $n = registerBoolean(`"$($r.Id)`", GameRuleCategory.$($r.Category), $($r.Default));$nl")
                }
            }
            if ($hasBool) {
                [void]$sb.Append(@"

   private static DeferredHolder<GameRule<?>, GameRule<Boolean>> registerBoolean(String registryname, GameRuleCategory category, boolean value) {
      return REGISTRY.register(registryname, () -> new GameRule<>(category, GameRuleType.BOOL, BoolArgumentType.bool(), GameRuleTypeVisitor::visitBoolean,
            Codec.BOOL, b -> b ? 1 : 0, value, FeatureFlagSet.of()));
   }
"@)
            }
            if ($hasInt) {
                [void]$sb.Append(@"

   private static DeferredHolder<GameRule<?>, GameRule<Integer>> registerInteger(String registryname, GameRuleCategory category, int value) {
      return REGISTRY.register(registryname, () -> new GameRule<>(category, GameRuleType.INT, IntegerArgumentType.integer(Integer.MIN_VALUE, Integer.MAX_VALUE),
            GameRuleTypeVisitor::visitInteger, Codec.intRange(Integer.MIN_VALUE, Integer.MAX_VALUE), i -> i, value, FeatureFlagSet.of()));
   }
"@)
            }
            [void]$sb.Append("$nl}$nl")
            $newText = $sb.ToString()
            if ($newText -ne $t) {
                [IO.File]::WriteAllText($file.FullName, $newText)
                $touched++
            }
        }

        $fieldNames = @($deferredFields)
        if ($fieldNames.Count -eq 0) { $fieldNames = @($ruleMap.Keys) }
        if ($fieldNames.Count -gt 0) {
            [void]$converted.Add([pscustomobject]@{ ClassName = $className; Package = $pkg; Fields = $fieldNames })
        }
    }

    foreach ($conv in $converted) {
        $className = $conv.ClassName
        $pkg = $conv.Package
        $fieldAlt = ($conv.Fields | ForEach-Object { [regex]::Escape($_) }) -join '|'
        if ([string]::IsNullOrWhiteSpace($fieldAlt)) { continue }
        $useRx = [regex]::new("(?<![\w.])$([regex]::Escape($className))\.(?:$fieldAlt)(?!\s*\.get\s*\()")
        foreach ($file in @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue)) {
            if ($file.Name -eq "$className.java") { continue }
            $u = [IO.File]::ReadAllText($file.FullName)
            $orig = $u
            $u = $useRx.Replace($u, '$0.get()')
            $isMod = $u -match '@Mod\s*\(' -and $u -match '\.REGISTRY\.register\s*\(\s*\w+\s*\)'
            if ($isMod -and $u -notmatch [regex]::Escape("$className.REGISTRY.register")) {
                $importStmt = "import $pkg.$className;"
                if ($u -notmatch [regex]::Escape($importStmt)) {
                    $initImports = [regex]::Matches($u, "(?m)^import\s+$([regex]::Escape($pkg))\.[A-Za-z0-9_]+;")
                    if ($initImports.Count -gt 0) {
                        $lastImp = $initImports[$initImports.Count - 1]
                        $u = $u.Insert($lastImp.Index + $lastImp.Length, "$nl$importStmt")
                    } else {
                        $u = [regex]::Replace($u, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}$importStmt${nl}", 1)
                    }
                }
                $regCalls = [regex]::Matches($u, '([A-Za-z0-9_.]+)\.REGISTRY\.register\(\s*(\w+)\s*\);')
                if ($regCalls.Count -gt 0) {
                    $last = $regCalls[$regCalls.Count - 1]
                    $bus = $last.Groups[2].Value
                    $lineStart = $u.LastIndexOf("`n", $last.Index)
                    $indent = if ($lineStart -ge 0) { $u.Substring($lineStart + 1, $last.Index - $lineStart - 1) } else { '      ' }
                    if ($indent -notmatch '^\s+$') { $indent = '      ' }
                    $insert = "$indent$className.REGISTRY.register($bus);"
                    $u = $u.Insert($last.Index + $last.Length, "$nl$insert")
                }
            }
            if ($u -ne $orig) {
                [IO.File]::WriteAllText($file.FullName, $u)
                $touched++
            }
        }
    }

    return $touched
}

function Invoke-Minecraft262CompileRepairPass {
    <#
    .SYNOPSIS
      Post-1.21.11 / 26.2 compile repairs proven on gecko_kings:
      FogRenderer package, InteractionResult import, Tier→ToolMaterial,
      custom GameRules → DeferredRegister(Registries.GAME_RULE) (not static registerBoolean),
      ArmorMaterial.Layer → 8-arg equipment record, DeferredSpawnEggItem → SpawnEggItem,
      SOUND_EVENT.get→getValue, HierarchicalModel animator strip, final renderToBuffer strip,
      Capabilities.FluidHandler stub, fluid fog API reshape.
    #>
    param([string]$Root)

    $javaRoot = Join-Path $Root 'src\main\java'
    $nl = [Environment]::NewLine
    $touched = 0

    foreach ($file in @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue)) {
        $t = [IO.File]::ReadAllText($file.FullName)
        $o = $t

        # --- Simple package / type remaps ---
        $t = $t.Replace('import net.minecraft.client.renderer.FogRenderer', 'import net.minecraft.client.renderer.fog.FogRenderer')
        $t = $t.Replace('net.minecraft.client.renderer.FogRenderer.', 'net.minecraft.client.renderer.fog.FogRenderer.')
        $t = $t -replace 'import\s+net\.minecraft\.world\.item\.context\.InteractionResult\s*;', 'import net.minecraft.world.InteractionResult;'
        $t = $t -replace 'import\s+net\.minecraft\.world\.item\.InteractionResult\s*;', 'import net.minecraft.world.InteractionResult;'
        if ($t -match '(?<![\w.])InteractionResult\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.InteractionResult\s*;') {
            $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.InteractionResult;${nl}", 1)
        }

        # Mixin pattern-matching: `this instanceof T` is illegal when the mixin class is unrelated to T
        # (catfighting Entity/LivingEntity mixins → Cat). Cast through Object first.
        if ($t -match '@Mixin' -and $t -match '(?<!\(Object\)\s)(?<![\w.])this\s+instanceof\s+') {
            $t = [regex]::Replace($t, '(?<!\(Object\)\s)(?<![\w.])this\s+instanceof\s+', '(Object) this instanceof ')
        }

        # CASE-006: FlyingMob / FlyingAnimal removed (primers 1.21.6 / 26.2). Leaf heuristic:
        # Ghast / HappyGhast / Phantom / Bee.isFlying() — omnidirectionalAirMover() is protected.
        if ($t -match 'FlyingMob|FlyingAnimal') {
            $t = $t -replace 'import\s+net\.minecraft\.world\.entity\.FlyingMob\s*;\r?\n', ''
            $t = $t -replace 'import\s+net\.minecraft\.world\.entity\.animal\.FlyingAnimal\s*;\r?\n', ''
            $t = $t -replace '(?<![\w.])(\w+)\s+instanceof\s+FlyingAnimal\s+(\w+)\s*&&\s*\2\.isFlying\s*\(\s*\)',
                '($1 instanceof Ghast || $1 instanceof HappyGhast || $1 instanceof Phantom || $1 instanceof Bee bee && bee.isFlying())'
            $t = $t -replace '(?<![\w.])(\w+)\s+instanceof\s+FlyingMob\b',
                '($1 instanceof Ghast || $1 instanceof HappyGhast || $1 instanceof Phantom)'
            $t = $t -replace '(?<![\w.])(\w+)\s+instanceof\s+FlyingAnimal\b',
                '($1 instanceof Bee bee && bee.isFlying())'
            if ($t -match '\bGhast\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.entity\.monster\.Ghast\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.entity.monster.Ghast;${nl}", 1)
            }
            if ($t -match '\bHappyGhast\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.entity\.animal\.happyghast\.HappyGhast\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.entity.animal.happyghast.HappyGhast;${nl}", 1)
            }
            if ($t -match '\bPhantom\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.entity\.monster\.Phantom\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.entity.monster.Phantom;${nl}", 1)
            }
            if ($t -match '\bBee\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.entity\.animal\.bee\.Bee\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.entity.animal.bee.Bee;${nl}", 1)
            }
        }

        # CASE-006: CatVariant.X / FrogVariant.X constants → CatVariants / FrogVariants ResourceKeys
        if ($t -match '(?<![\w.])CatVariant\.[A-Z_]+' -or $t -match '(?<![\w.])FrogVariant\.[A-Z_]+') {
            $t = $t -replace '(?<![\w.])CatVariant\.([A-Z_]+)\b', 'CatVariants.$1'
            $t = $t -replace '(?<![\w.])FrogVariant\.([A-Z_]+)\b', 'FrogVariants.$1'
            if ($t -match '\bCatVariants\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.entity\.animal\.feline\.CatVariants\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.entity.animal.feline.CatVariants;${nl}", 1)
            }
            if ($t -match '\bFrogVariants\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.entity\.animal\.frog\.FrogVariants\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.entity.animal.frog.FrogVariants;${nl}", 1)
            }
        }

        # CASE-006: cpw.mods.modlauncher Launcher VERSION probe → FMLLoader production check
        if ($t -match 'cpw\.mods\.modlauncher' -or $t -match 'Launcher\.INSTANCE\.environment') {
            $t = $t -replace 'import\s+cpw\.mods\.modlauncher\.Launcher\s*;\r?\n', ''
            $t = $t -replace 'import\s+cpw\.mods\.modlauncher\.api\.IEnvironment\.Keys\s*;\r?\n', ''
            $t = $t -replace 'import\s+cpw\.mods\.modlauncher\.api\.TypesafeMap\.Key\s*;\r?\n', ''
            $t = $t -replace 'import\s+java\.util\.Optional\s*;\r?\n', ''
            $t = [regex]::Replace($t,
                '(?s)Optional<\s*String\s*>\s+\w+\s*=\s*Launcher\.INSTANCE\.environment\(\)\.getProperty\s*\(\s*\(Key\)\s*Keys\.VERSION\.get\(\)\s*\)\s*;\s*if\s*\(\s*\w+\.isPresent\(\)\s*&&\s*"MOD_DEV"\.equals\(\s*\w+\.get\(\)\s*\)\s*\)\s*\{\s*DebugManager\.setDevelopmentEnvironment\s*\(\s*true\s*\)\s*;\s*\}',
                'if (!FMLLoader.getCurrent().isProduction()) { DebugManager.setDevelopmentEnvironment(true); }')
            if ($t -match 'FMLLoader' -and $t -notmatch 'import\s+net\.neoforged\.fml\.loading\.FMLLoader\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.neoforged.fml.loading.FMLLoader;${nl}", 1)
            }
        }
        # InteractionResultHolder removed — Item.use returns InteractionResult
        $t = $t -replace 'InteractionResultHolder<\s*ItemStack\s*>', 'InteractionResult'
        $t = $t -replace 'import\s+net\.minecraft\.world\.InteractionResultHolder\s*;\r?\n', ''

        # BuiltInRegistries.*.get(Identifier) → getValue (Optional Holder → T)
        $t = $t -replace '\(SoundEvent\)\s*BuiltInRegistries\.SOUND_EVENT\.get\(', 'BuiltInRegistries.SOUND_EVENT.getValue('
        $t = $t -replace 'BuiltInRegistries\.SOUND_EVENT\.get\(Identifier\.parse\(', 'BuiltInRegistries.SOUND_EVENT.getValue(Identifier.parse('

        # DeferredSpawnEggItem → SpawnEggItem(properties.spawnEgg(type.get()))
        if ($t -match 'DeferredSpawnEggItem') {
            $t = $t -replace 'import\s+net\.neoforged\.neoforge\.common\.DeferredSpawnEggItem\s*;', 'import net.minecraft.world.item.SpawnEggItem;'
            $t = [regex]::Replace($t,
                'new\s+DeferredSpawnEggItem\s*\(\s*([^,]+)\s*,\s*[^,]+,\s*[^,]+,\s*new\s+Properties\s*\(\s*\)\s*\)',
                'new SpawnEggItem(new Properties().spawnEgg($1.get()))')
            $t = [regex]::Replace($t,
                'REGISTRY\.register\s*\(\s*"([^"]+_spawn_egg)"\s*,\s*\(\)\s*->\s*new\s+SpawnEggItem\(new Properties\(\)\.spawnEgg\(([^)]+)\)\)\s*\)',
                'REGISTRY.registerItem("$1", p -> new SpawnEggItem(p.spawnEgg($2)))')
        }

        # Capabilities.FluidHandler → Capabilities.Fluid (API reshape; bucket wrapper often stubbed)
        if ($t -match 'Capabilities\.FluidHandler') {
            $t = $t -replace 'import\s+net\.neoforged\.neoforge\.capabilities\.Capabilities\.FluidHandler\s*;', 'import net.neoforged.neoforge.capabilities.Capabilities;'
            $t = $t -replace 'FluidHandler\.ITEM', 'Capabilities.Fluid.ITEM'
            # FluidBucketWrapper no longer matches ResourceHandler<FluidResource> — neutralize registration body
            if ($t -match 'FluidBucketWrapper|Capabilities\.Fluid\.ITEM') {
                $t = [regex]::Replace($t,
                    '(?s)@SubscribeEvent\s+public static void registerCapabilities\s*\(\s*RegisterCapabilitiesEvent\s+\w+\s*\)\s*\{(?:[^{}]|\{[^{}]*\})*\}',
                    "@SubscribeEvent${nl}   public static void registerCapabilities(RegisterCapabilitiesEvent event) {${nl}      /* 26.2: Capabilities.Fluid.ITEM uses ResourceHandler; FluidBucketWrapper deferred */${nl}   }")
            }
        }

        # FogShape / old fluid fog signatures → 26.2 FogData API (or strip body)
        if ($t -match 'FogShape|FogRenderer\.FogMode|modifyFogRender|modifyFogColor') {
            $t = $t -replace 'import\s+com\.mojang\.blaze3d\.shaders\.FogShape\s*;\r?\n', ''
            $t = $t -replace 'import\s+net\.minecraft\.client\.renderer\.fog\.FogRenderer\.FogMode\s*;\r?\n', ''
            $t = $t -replace 'import\s+net\.minecraft\.client\.renderer\.FogRenderer\.FogMode\s*;\r?\n', ''
            if ($t -match 'modifyFogRender|modifyFogColor' -and $t -notmatch 'import\s+net\.minecraft\.client\.renderer\.fog\.FogData\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                    "`$1${nl}import net.minecraft.client.renderer.fog.FogData;${nl}import net.minecraft.client.renderer.fog.environment.FogEnvironment;${nl}import org.joml.Vector4f;${nl}", 1)
            }
            # Vector3f-returning modifyFogColor → void Vector4f mutator
            $t = [regex]::Replace($t,
                '(?s)public\s+Vector3f\s+modifyFogColor\s*\(\s*Camera\s+(\w+)\s*,\s*float\s+(\w+)\s*,\s*ClientLevel\s+(\w+)\s*,\s*int\s+(\w+)\s*,\s*float\s+(\w+)\s*,\s*Vector3f\s+(\w+)\s*\)\s*\{.*?return\s+new\s+Vector3f\s*\(([^;]+)\);\s*\}',
                'public void modifyFogColor(Camera $1, float $2, ClientLevel $3, int $4, float $5, Vector4f $6) { $6.set($7, $6.w); }')
            $t = [regex]::Replace($t,
                '(?s)public\s+void\s+modifyFogRender\s*\(\s*Camera\s+(\w+)\s*,\s*FogMode\s+\w+\s*,\s*float\s+(\w+)\s*,\s*float\s+(\w+)\s*,\s*float\s+\w+\s*,\s*float\s+\w+\s*,\s*FogShape\s+\w+\s*\)\s*\{.*?\}',
                'public void modifyFogRender(Camera $1, FogEnvironment environment, float $2, float $3, FogData fogData) { }')
        }

        # Tier anonymous class → ToolMaterial + Properties.sword (MCreator wristblade/sword)
        if ($t -match '(?s)private static final Tier TOOL_TIER = new Tier\(\)\s*\{') {
            $m = [regex]::Match($t, '(?s)private static final Tier TOOL_TIER = new Tier\(\)\s*\{(.*?)\n   \};')
            $body = if ($m.Success) { $m.Groups[1].Value } else { '' }
            $uses = if ($body -match 'getUses\(\)\s*\{\s*return\s+(\d+)') { $Matches[1] } else { '250' }
            $speed = if ($body -match 'getSpeed\(\)\s*\{\s*return\s+([0-9.]+)F?') { "$($Matches[1])F" } else { '6.0F' }
            $dmg = if ($body -match 'getAttackDamageBonus\(\)\s*\{\s*return\s+([0-9.]+)F?') { "$($Matches[1])F" } else { '0.0F' }
            $ench = if ($body -match 'getEnchantmentValue\(\)\s*\{\s*return\s+(\d+)') { $Matches[1] } else { '14' }
            $incorrect = if ($body -match 'return\s+(BlockTags\.[A-Z0-9_]+)') { $Matches[1] } else { 'BlockTags.INCORRECT_FOR_IRON_TOOL' }
            $atk = '1.0F'; $atkSpeed = '-2.4F'
            if ($t -match 'SwordItem\.createAttributes\(\s*TOOL_TIER\s*,\s*([0-9.F]+)\s*,\s*([-0-9.F]+)') {
                $atk = $Matches[1]; if ($atk -notmatch 'F$') { $atk = "$atk`F" }
                $atkSpeed = $Matches[2]; if ($atkSpeed -notmatch 'F$') { $atkSpeed = "$atkSpeed`F" }
            }
            $modidGuess = 'minecraft'
            if ($t -match '"([a-z0-9_]+):[a-z0-9_/]+"') { $modidGuess = $Matches[1] }
            $base = ([IO.Path]::GetFileNameWithoutExtension($file.Name) -replace 'Item$','').ToLowerInvariant()
            $repairTag = "${modidGuess}:${base}_repair_items"
            $toolMat = "private static final ToolMaterial TOOL_MATERIAL = new ToolMaterial($incorrect, $uses, $speed, $dmg, $ench, TagKey.create(Registries.ITEM, Identifier.parse(`"$repairTag`")));"
            $t = [regex]::Replace($t, '(?s)private static final Tier TOOL_TIER = new Tier\(\)\s*\{.*?\n   \};', $toolMat)
            $t = $t -replace 'import\s+net\.minecraft\.world\.item\.Tier\s*;', 'import net.minecraft.world.item.ToolMaterial;'
            # .NET Replace treats $atk as group refs — concatenate instead
            $swordSuper = 'super(new Properties().sword(TOOL_MATERIAL, ' + $atk + ', ' + $atkSpeed + '))'
            $t = [regex]::Replace($t,
                'super\(\s*TOOL_TIER\s*,\s*new Properties\(\)\.attributes\(SwordItem\.createAttributes\(\s*TOOL_TIER\s*,\s*[0-9.F]+\s*,\s*[-0-9.F]+\s*\)\)\s*\)',
                $swordSuper)
            $t = $t -replace 'super\(\s*TOOL_TIER\s*,', 'super(TOOL_MATERIAL,'
            if ($t -match 'gecko_kings_avp_mod|GeckoKingsAvpMod') {
                $t = $t.Replace('Identifier.parse("minecraft:' + $base + '_repair_items")', 'Identifier.parse("gecko_kings_avp_mod:' + $base + '_repair_items")')
            }
            if ($t -notmatch 'import\s+net\.minecraft\.world\.item\.ToolMaterial\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.item.ToolMaterial;${nl}", 1)
            }
            if ($t -match 'TagKey\.create\(Registries\.ITEM' -and $t -notmatch 'import\s+net\.minecraft\.core\.registries\.Registries\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.core.registries.Registries;${nl}", 1)
            }
            if ($t -match 'Identifier\.parse' -and $t -notmatch 'import\s+net\.minecraft\.resources\.Identifier\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.resources.Identifier;${nl}", 1)
            }
            if ($t -match 'TagKey\.create' -and $t -notmatch 'import\s+net\.minecraft\.tags\.TagKey\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.tags.TagKey;${nl}", 1)
            }
        }
        elseif ($t -match 'import\s+net\.minecraft\.world\.item\.Tier\s*;') {
            $t = $t -replace 'import\s+net\.minecraft\.world\.item\.Tier\s*;', 'import net.minecraft.world.item.ToolMaterial;'
            $t = $t -replace '(?<![\w.])Tier\b', 'ToolMaterial'
        }

        # Nested GameRules.BooleanValue/Key leftovers only (custom rules: DeferredRegister GAME_RULE)
        if ($t -match 'import\s+net\.minecraft\.world\.level(\.gamerules)?\.GameRules\.(BooleanValue|IntegerValue|Category|Key)') {
            $t = $t -replace 'import\s+net\.minecraft\.world\.level\.gamerules\.GameRules\.BooleanValue\s*;\r?\n', ''
            $t = $t -replace 'import\s+net\.minecraft\.world\.level\.gamerules\.GameRules\.IntegerValue\s*;\r?\n', ''
            $t = $t -replace 'import\s+net\.minecraft\.world\.level\.gamerules\.GameRules\.Category\s*;\r?\n', ''
            $t = $t -replace 'import\s+net\.minecraft\.world\.level\.gamerules\.GameRules\.Key\s*;\r?\n', ''
            $t = $t -replace 'import\s+net\.minecraft\.world\.level\.GameRules\.(BooleanValue|IntegerValue|Category|Key)\s*;\r?\n', ''
        }

        # ArmorMaterial.Layer MCreator constructor → 8-arg equipment record (Map.of defense)
        if ($t -match 'List\.of\(\s*new\s+Layer\s*\(' -or $t -match 'new\s+Layer\s*\(\s*Identifier\.parse') {
            $dur = 15
            if ($t -match 'getDurability\s*\(\s*(\d+)\s*\)') { $dur = [int]$Matches[1] }
            $enchant = '5'
            $sound = 'DeferredHolder.create(Registries.SOUND_EVENT, Identifier.parse("item.armor.equip_iron"))'
            if ($t -match ',\s*(\d+)\s*,\s*(DeferredHolder\.create\(Registries\.SOUND_EVENT,\s*Identifier\.parse\("[^"]+"\))\s*,') {
                $enchant = $Matches[1]
                $sound = $Matches[2]
            }
            $tough = '0.0F'; $knock = '0.0F'; $assetId = 'minecraft:iron'
            if ($t -match 'new\s+Layer\s*\(\s*Identifier\.parse\("([^"]+)"\)\s*\)\s*\)\s*,\s*([0-9.]+)F?\s*,\s*([0-9.]+)F?') {
                $assetId = $Matches[1]; $tough = $Matches[2]; $knock = $Matches[3]
                if ($tough -notmatch 'F$') { $tough = $tough + 'F' }
                if ($knock -notmatch 'F$') { $knock = $knock + 'F' }
            }
            $puts = [regex]::Matches($t, 'map\.put\(ArmorType\.(\w+),\s*(\d+)\)')
            $mapEntries = @($puts | ForEach-Object { 'ArmorType.' + $_.Groups[1].Value + ', ' + $_.Groups[2].Value })
            $mapExpr = if ($mapEntries.Count -gt 0) { 'Map.of(' + ($mapEntries -join ', ') + ')' } else { 'Map.of()' }
            $repair = $assetId + '_repair_items'
            if ($assetId -match '^([^:]+):(.+)$') { $repair = $Matches[1] + ':' + $Matches[2] + '_repair_items' }
            $newCtor = 'ArmorMaterial armorMaterial = new ArmorMaterial(' + $dur + ', ' + $mapExpr + ', ' + $enchant + ', ' + $sound + ', ' + $tough + ', ' + $knock + ', TagKey.create(Registries.ITEM, Identifier.parse("' + $repair + '")), ResourceKey.create(EquipmentAssets.ROOT_ID, Identifier.parse("' + $assetId + '")));' + "`r`n            registerHelper.register"
            $t2 = [regex]::Replace($t, '(?s)ArmorMaterial\s+armorMaterial\s*=\s*new\s+ArmorMaterial\s*\(.*?\);\s*registerHelper\.register', $newCtor, 1)
            if ($t2 -ne $t) { $t = $t2 }
            $t = $t -replace 'import\s+net\.minecraft\.world\.item\.equipment\.ArmorMaterial\.Layer\s*;\r?\n', ''
            $t = $t -replace 'import\s+net\.minecraft\.world\.item\.ArmorMaterial\.Layer\s*;\r?\n', ''
            if ($t -notmatch 'import\s+net\.minecraft\.world\.item\.equipment\.EquipmentAssets\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                    "`$1${nl}import net.minecraft.tags.TagKey;${nl}import net.minecraft.resources.ResourceKey;${nl}import net.minecraft.world.item.equipment.EquipmentAssets;${nl}", 1)
            }
            $t = $t -replace 'public static Holder<ArmorMaterial> ARMOR_MATERIAL = null;', 'public static ArmorMaterial ARMOR_MATERIAL;'
            $t = $t -replace 'public static Holder<ArmorMaterial> ARMOR_MATERIAL;', 'public static ArmorMaterial ARMOR_MATERIAL;'
            $t = $t -replace 'ARMOR_MATERIAL = BuiltInRegistries\.ARMOR_MATERIAL\.wrapAsHolder\(armorMaterial\);', 'ARMOR_MATERIAL = armorMaterial;'
        }

        # HierarchicalModel animator inner classes — drop broken animator; keep model
        if ($t -match 'HierarchicalModel') {
            $t = $t -replace 'import\s+net\.minecraft\.client\.model\.HierarchicalModel\s*;\r?\n', ''
            # Swimmer-style: use base model in super(), delete AnimatedModel nested class
            $t = [regex]::Replace($t,
                'super\(\s*context\s*,\s*new\s+\w+\.AnimatedModel\s*\(\s*context\.bakeLayer\(([^)]+)\)\s*\)\s*,',
                'super(context, new ModelXenomorph_Swimmer(context.bakeLayer($1)),')
            # Generic: AnimatedModel(bakeLayer(X)) → model type from extends clause if possible
            if ($t -match 'extends\s+MobRenderer<[^,]+,\s*[^,]+,\s*(\w+)\s*>') {
                $modelType = $Matches[1]
                $t = [regex]::Replace($t,
                    "super\(\s*context\s*,\s*new\s+ModelXenomorph_Swimmer\s*\(\s*context\.bakeLayer\(([^)]+)\)\s*\)\s*,",
                    "super(context, new $modelType(context.bakeLayer(`$1)),")
                $t = [regex]::Replace($t,
                    "super\(\s*context\s*,\s*new\s+\w+\.AnimatedModel\s*\(\s*context\.bakeLayer\(([^)]+)\)\s*\)\s*,",
                    "super(context, new $modelType(context.bakeLayer(`$1)),")
            }
            $t = [regex]::Replace($t, '(?s)\s*private static final class AnimatedModel extends \w+ \{.*?\n   \}\s*', "${nl}")
        }

        # Model.renderToBuffer overrides are final in 26.2 — remove override methods
        if ($t -match 'void\s+renderToBuffer\s*\(\s*PoseStack') {
            $t = [regex]::Replace($t,
                '(?s)\s*public void renderToBuffer\s*\(\s*PoseStack\s+\w+\s*,\s*VertexConsumer\s+\w+\s*,\s*int\s+\w+\s*,\s*int\s+\w+\s*,\s*int\s+\w+\s*\)\s*\{(?:[^{}]|\{[^{}]*\})*\}',
                '')
        }

        # Old getArmorTexture(..., Layer, ...) removed with equipment assets
        if ($t -match 'getArmorTexture\s*\([^)]*Layer') {
            $t = [regex]::Replace($t, '(?s)\s*(?:@Override\s*)?public Identifier getArmorTexture\s*\([^)]*Layer[^)]*\)\s*\{(?:[^{}]|\{[^{}]*\})*\}', '')
        }

        # Old entity-typed glow RenderLayer blocks break 26.2 RenderState generics — drop for compile
        if ($t -match 'this\.addLayer\(\s*new RenderLayer<') {
            $t = [regex]::Replace($t, '(?s)\s*this\.addLayer\(\s*new RenderLayer<[^>]+>\(this\)\s*\{.*?\n\s*\}\s*\);', '')
        }

        # MobRenderer/EntityRenderer createRenderState stub at class scope (not inside ctors with nested addLayer)
        if ($t -match 'extends\s+(MobRenderer|EntityRenderer)<' -and $t -notmatch 'createRenderState\s*\(') {
            $t = [regex]::Replace($t, '\r?\n\}\s*$',
                "${nl}${nl}   public net.minecraft.client.renderer.entity.state.LivingEntityRenderState createRenderState() { return new net.minecraft.client.renderer.entity.state.LivingEntityRenderState(); }${nl}}${nl}")
        }

        # --- CASE-005 gecko_kings wave (26.2 API leftovers) ---
        # ServerBossEvent now requires UUID first
        if ($t -match 'new\s+ServerBossEvent\s*\(\s*this\.getDisplayName\s*\(') {
            if ($t -notmatch 'import\s+java\.util\.UUID\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import java.util.UUID;${nl}", 1)
            }
            $t = $t -replace 'new\s+ServerBossEvent\s*\(\s*this\.getDisplayName\s*\(\s*\)\s*,', 'new ServerBossEvent(UUID.randomUUID(), this.getDisplayName(),'
        }

        # Mob.customServerAiStep requires ServerLevel
        if ($t -match 'customServerAiStep\s*\(\s*\)') {
            if ($t -notmatch 'import\s+net\.minecraft\.server\.level\.ServerLevel\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.server.level.ServerLevel;${nl}", 1)
            }
            $t = $t -replace '(protected|public)\s+void\s+customServerAiStep\s*\(\s*\)', '$1 void customServerAiStep(ServerLevel level)'
            $t = $t -replace 'super\.customServerAiStep\s*\(\s*\)\s*;', 'super.customServerAiStep(level);'
        }

        # AbstractArrow: inGround field → isInGround(); EntityType<? extends Self> → <? extends AbstractArrow>
        if ($t -match 'extends\s+AbstractArrow\b') {
            $t = $t -replace '(?<![\w.])this\.inGround\b(?!\s*\()', 'this.isInGround()'
            $t = [regex]::Replace($t,
                'EntityType<\?\s+extends\s+(\w+AcidEntity|\w+ArrowEntity|\w+ProjectileEntity)>',
                'EntityType<? extends AbstractArrow>')
        }
        # CASE-005: AbstractArrow ctor is EntityType<? extends AbstractArrow>; Builder.of(Foo::new)
        # infers EntityType<Entity> and fails. Pin the type argument on acid/arrow builders.
        $t = [regex]::Replace($t,
            'EntityType\.Builder\.of\(\s*(\w+(?:Acid|Arrow)Entity)::new\s*,',
            'EntityType.Builder.<$1>of($1::new,')

        # Vineflower swim LookControl: Entity.this used where getXRot() was intended
        $t = [regex]::Replace($t, 'rotlerp\(\s*(\w+Entity)\.this\s*,', 'rotlerp($1.this.getXRot(),')
        $t = [regex]::Replace($t, 'Mth\.(cos|sin)\(\s*(\w+Entity)\.this\s*\*', 'Mth.$1($2.this.getXRot() *')

        # Entity.getLevel() → level(); spawnAtLocation(level, …) needs ServerLevel
        $t = $t -replace '(?<![\w.])this\.getLevel\s*\(\s*\)', 'this.level()'
        if ($t -match 'spawnAtLocation\s*\(\s*level\s*,') {
            if ($t -notmatch 'import\s+net\.minecraft\.server\.level\.ServerLevel\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.server.level.ServerLevel;${nl}", 1)
            }
            $t = $t -replace 'spawnAtLocation\s*\(\s*level\s*,', 'spawnAtLocation((ServerLevel) this.level(),'
        }

        # Registries.ARMOR_MATERIAL removed in 26.2 — ArmorMaterial is a plain record used via humanoidArmor
        if ($t -match 'Registries\.ARMOR_MATERIAL' -and $t -match 'new\s+ArmorMaterial\s*\(') {
            $m = [regex]::Match($t, 'ArmorMaterial\s+armorMaterial\s*=\s*(new\s+ArmorMaterial\s*\(.*?\))\s*;', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($m.Success) {
                $ctor = $m.Groups[1].Value
                # Balanced-brace strip of registerArmorMaterial (nested RegisterEvent lambda)
                $t2 = [regex]::Replace($t,
                    '(?s)public\s+static\s+(?:final\s+)?ArmorMaterial\s+ARMOR_MATERIAL\s*;\s*@SubscribeEvent\s*public\s+static\s+void\s+registerArmorMaterial\s*\(\s*RegisterEvent\s+\w+\s*\)\s*\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\}',
                    "public static final ArmorMaterial ARMOR_MATERIAL = $ctor;", 1)
                if ($t2 -eq $t) {
                    # Fallback: drop event.register(Registries.ARMOR_MATERIAL, ...) body and keep static field
                    $t2 = [regex]::Replace($t,
                        '(?s)@SubscribeEvent\s*public\s+static\s+void\s+registerArmorMaterial\s*\(\s*RegisterEvent\s+\w+\s*\)\s*\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\}',
                        '', 1)
                    $t2 = $t2 -replace 'public\s+static\s+ArmorMaterial\s+ARMOR_MATERIAL\s*;',
                        "public static final ArmorMaterial ARMOR_MATERIAL = $ctor;"
                }
                $t = $t2
                if ($t -notmatch '\bRegisterEvent\b') {
                    $t = $t -replace 'import\s+net\.neoforged\.neoforge\.registries\.RegisterEvent\s*;\r?\n', ''
                }
            }
        }

        # Legacy IClientItemExtensions humanoid armor model hooks are not the 26.2 path
        # (HumanoidModel crouching/riding/young removed; equipment assets own armor models).
        # Must run even when ArmorMaterial is already a static record (CASE-005 leftover).
        # Brace-depth walker: nested anon-class + method + if exceeds fixed-depth regex.
        if ($t -match 'registerItemExtensions' -and ($t -match 'getHumanoidArmorModel' -or $t -match 'armorModel\.crouching')) {
            $rxExt = [regex]'@SubscribeEvent\s*public\s+static\s+void\s+registerItemExtensions\s*\(\s*RegisterClientExtensionsEvent\s+\w+\s*\)\s*\{'
            $mExt = $rxExt.Match($t)
            if ($mExt.Success) {
                $braceStart = $t.IndexOf('{', $mExt.Index + $mExt.Length - 1)
                $depth = 0
                $end = -1
                for ($i = $braceStart; $i -lt $t.Length; $i++) {
                    $ch = $t[$i]
                    if ($ch -eq '{') { $depth++ }
                    elseif ($ch -eq '}') {
                        $depth--
                        if ($depth -eq 0) { $end = $i; break }
                    }
                }
                if ($end -ge 0) {
                    $replacement = "@SubscribeEvent${nl}   public static void registerItemExtensions(RegisterClientExtensionsEvent event) {${nl}      // client armor model extensions deferred to equipment assets${nl}   }"
                    $t = $t.Substring(0, $mExt.Index) + $replacement + $t.Substring($end + 1)
                    # Drop imports only referenced by the removed hook body
                    $bodyNoImp = [regex]::Replace($t, '(?m)^import\s+[^;]+;\s*\r?\n', '')
                    foreach ($pair in @(
                        @('net.neoforged.neoforge.client.extensions.common.IClientItemExtensions', 'IClientItemExtensions'),
                        @('net.neoforged.api.distmarker.OnlyIn', 'OnlyIn'),
                        @('net.neoforged.api.distmarker.Dist', 'Dist'),
                        @('net.minecraft.client.model.HumanoidModel', 'HumanoidModel'),
                        @('net.minecraft.client.model.geom.ModelPart', 'ModelPart'),
                        @('net.minecraft.client.Minecraft', 'Minecraft'),
                        @('net.neoforged.neoforge.registries.RegisterEvent', 'RegisterEvent')
                    )) {
                        if ($bodyNoImp -notmatch ("\b{0}\b" -f [regex]::Escape($pair[1]))) {
                            $t = $t -replace ("(?m)^import\s+{0}\s*;\r?\n" -f [regex]::Escape($pair[0])), ''
                        }
                    }
                }
            }
        }

        # Ingredient.of(ItemStack[]) no longer exists — prefer ItemLike
        $t = [regex]::Replace($t,
            'Ingredient\.of\s*\(\s*new\s+ItemStack\[\]\s*\{\s*new\s+ItemStack\s*\(\s*(Items\.\w+)\s*\)\s*\}\s*\)',
            'Ingredient.of($1)')
        $t = [regex]::Replace($t,
            'Ingredient\.of\s*\(\s*new\s+ItemStack\[\]\s*\{\s*new\s+ItemStack\s*\(\s*((?:\(ItemLike\))?[^}]+?)\s*\)\s*\}\s*\)',
            'Ingredient.of($1)')

        # Potion(String name, MobEffectInstance...) — drop array wrapper when present
        $t = [regex]::Replace($t,
            'REGISTRY\.register\(\s*"([^"]+)"\s*,\s*\(\)\s*->\s*new\s+Potion\s*\(\s*new\s+MobEffectInstance\[\]\s*\{\s*(new\s+MobEffectInstance\s*\([^}]+\))\s*\}\s*\)\s*\)',
            'REGISTRY.register("$1", () -> new Potion("$1", $2))')

        # EntityType.Builder.build(registryname string) → ResourceKey
        if ($t -match 'entityTypeBuilder\.build\(\s*registryname\s*\)') {
            if ($t -notmatch 'import\s+net\.minecraft\.resources\.ResourceKey\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.resources.ResourceKey;${nl}import net.minecraft.resources.Identifier;${nl}import net.minecraft.core.registries.Registries;${nl}", 1)
            }
            # Prefer mod id from DeferredRegister.create(Registries.ENTITY_TYPE, "modid")
            $modIdForEnt = 'minecraft'
            if ($t -match 'DeferredRegister\.create\(\s*Registries\.ENTITY_TYPE\s*,\s*"([^"]+)"\s*\)') { $modIdForEnt = $Matches[1] }
            $t = $t -replace 'entityTypeBuilder\.build\(\s*registryname\s*\)',
                ("entityTypeBuilder.build(ResourceKey.create(Registries.ENTITY_TYPE, Identifier.parse(`"{0}:`" + registryname)))" -f $modIdForEnt)
        }

        # CASE-005 full-restore leftovers (procedures / effects / tools)
        # Multiline EntityType.is(TagKey) → builtInRegistryHolder().is
        $t = [regex]::Replace($t, '\.getType\(\)\s*\r?\n?\s*\.is\(', '.getType().builtInRegistryHolder().is(')
        $t = $t -replace 'MobEffects\.MOVEMENT_SLOWDOWN\b', 'MobEffects.SLOWNESS'
        $t = $t -replace 'MobEffects\.JUMP\b(?!_)', 'MobEffects.JUMP_BOOST'
        # AbstractThrownPotion is abstract; 26.2 splits splash/lingering
        if ($t -match 'new\s+AbstractThrownPotion\s*\(') {
            $t = $t -replace 'import\s+net\.minecraft\.world\.entity\.projectile\.throwableitemprojectile\.AbstractThrownPotion\s*;',
                'import net.minecraft.world.entity.projectile.throwableitemprojectile.ThrownSplashPotion;'
            if ($t -notmatch 'import\s+net\.minecraft\.world\.entity\.EntityTypes\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.world.entity.EntityTypes;${nl}", 1)
            }
            $t = $t -replace 'AbstractThrownPotion\s+(\w+)\s*=\s*new\s+AbstractThrownPotion\s*\(\s*EntityTypes\.POTION\s*,',
                'ThrownSplashPotion $1 = new ThrownSplashPotion(EntityTypes.SPLASH_POTION,'
            $t = $t -replace '(\w+)\.hasImpulse\s*=\s*true\s*;', '$1.setDeltaMovement($1.getDeltaMovement());'
        }
        # LevelAccessor spawn checks: GameRules live on ServerLevel in 26.2
        if ($t -match 'getLevelData\(\)\.getGameRules\(\)' -or $t -match '\(net\.minecraft\.world\.level\.Level\)world\)\.getGameRules\(\)') {
            if ($t -notmatch 'import\s+net\.minecraft\.server\.level\.ServerLevel\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1${nl}import net.minecraft.server.level.ServerLevel;${nl}", 1)
            }
            $t = [regex]::Replace($t,
                'return\s+world\.getLevelData\(\)\.getGameRules\(\)\.get\(([^)]+)\)\s*;',
                'return world instanceof ServerLevel _sl && _sl.getGameRules().get($1);')
            $t = [regex]::Replace($t,
                'return\s+\(\(net\.minecraft\.world\.level\.Level\)world\)\.getGameRules\(\)\.get\(([^)]+)\)\s*;',
                'return world instanceof ServerLevel _sl && _sl.getGameRules().get($1);')
        }
        # Vineflower/sword attack-speed token lost as bare F
        $t = $t -replace '\.sword\(\s*TOOL_MATERIAL\s*,\s*([0-9.]+F)\s*,\s*F\s*\)', '.sword(TOOL_MATERIAL, $1, -0.8F)'
        $t = Convert-Minecraft262LeafApiText -Text $t

        # CASE-005 MobEffect 26.2 — MUST live in this pass (runs for every route).
        # Previously only in Invoke-McreatorForge1201ResiduePass (gated on mcreator-1.20.1),
        # so NeoForge 1.21.x Mode B never applied them and installer runs regenerated the same errors.
        # Exact target: applyEffectTick(ServerLevel, LivingEntity, int); renderInventoryText removed.
        $t = $t -replace 'boolean isDurationEffectTick\(', 'boolean shouldApplyEffectTickThisTick('
        $t = [regex]::Replace($t,
            '(?m)^(\s*)(?:@Override\s*)?public void applyEffectTick\(LivingEntity (\w+), int (\w+)\) \{([^}]*)\}',
            '${1}public boolean applyEffectTick(ServerLevel level, LivingEntity $2, int $3) {$4 return true; }')
        $t = [regex]::Replace($t,
            '(?m)^(\s*)(?:@Override\s*)?public boolean applyEffectTick\(LivingEntity (\w+), int (\w+)\)',
            '${1}public boolean applyEffectTick(ServerLevel level, LivingEntity $2, int $3)')
        $t = $t -replace 'super\.applyEffectTick\(\s*(\w+)\s*,\s*(\w+)\s*\)', 'super.applyEffectTick(level, $1, $2)'
        if ($t -match 'applyEffectTick\(\s*ServerLevel\b' -and $t -notmatch 'import\s+net\.minecraft\.server\.level\.ServerLevel\s*;') {
            $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', ("`$1${nl}import net.minecraft.server.level.ServerLevel;${nl}"), 1)
        }
        $t = [regex]::Replace($t,
            '(?ms)\s*(?:@Override\s*)?public\s+boolean\s+renderInventoryText\s*\([^)]*\)\s*\{\s*return\s+false;\s*\}',
            '')
        $bodyNoImpFx = [regex]::Replace($t, '(?m)^import\s+[^;]+;\s*\r?\n', '')
        if ($bodyNoImpFx -notmatch '\bEffectRenderingInventoryScreen\b') {
            $t = $t -replace '(?m)^import\s+net\.minecraft\.client\.gui\.screens\.inventory\.EffectRenderingInventoryScreen\s*;\r?\n', ''
        }
        if ($bodyNoImpFx -notmatch '\bGuiGraphicsExtractor\b') {
            $t = $t -replace '(?m)^import\s+net\.minecraft\.client\.gui\.GuiGraphicsExtractor\s*;\r?\n', ''
        }

        # CASE-005 / primer entity-render-state: projectile EntityRenderer still on entity-typed render(...)
        # Rewrite to ArrowRenderer-shaped submit(state, PoseStack, SubmitNodeCollector, CameraRenderState).
        if ($file.Name -match 'Renderer\.java$' -and
            $t -match 'extends\s+EntityRenderer<' -and
            $t -match 'public\s+void\s+render\s*\(' -and
            ($t -match 'RenderTypes\.entityCutout' -or $t -match 'bufferIn\.getBuffer' -or $t -match 'SubmitNodeCollector bufferIn')) {
            $entMatch = [regex]::Match($t, 'extends\s+EntityRenderer<\s*([\w.]+)\s*,')
            $texMatch = [regex]::Match($t, 'Identifier\s+\w+\s*=\s*Identifier\.parse\("([^"]+)"\)')
            $modelField = [regex]::Match($t, 'private\s+final\s+(\w+)\s+(\w+)\s*;')
            if ($entMatch.Success -and $texMatch.Success -and $modelField.Success -and $t -notmatch 'public\s+void\s+submit\s*\(\s*LivingEntityRenderState') {
                $entType = $entMatch.Groups[1].Value
                $texLiteral = $texMatch.Groups[1].Value
                $modelType = $modelField.Groups[1].Value
                $modelName = $modelField.Groups[2].Value
                $pkgMatch = [regex]::Match($t, '(?m)^package\s+([^;]+);')
                $pkg = if ($pkgMatch.Success) { $pkgMatch.Groups[1].Value } else { 'unknown.client.renderer' }
                $clsMatch = [regex]::Match($t, 'public\s+class\s+(\w+)\s+extends')
                $cls = if ($clsMatch.Success) { $clsMatch.Groups[1].Value } else { $file.BaseName }
                $layerExpr = "$modelType.LAYER_LOCATION"
                $lm = [regex]::Match($t, 'bakeLayer\(([^)]+)\)')
                if ($lm.Success) { $layerExpr = $lm.Groups[1].Value }
                $origLines = $o -split "`r?`n"
                $modelImport = ($origLines | Where-Object { $_ -match ('import\s+[\w.]+' + [regex]::Escape($modelType) + '\s*;') } | Select-Object -First 1)
                if (-not $modelImport) { $modelImport = "import $pkg.$modelType;" -replace '\.client\.renderer\.', '.client.model.' }
                $entImport = ($origLines | Where-Object { $_ -match ('import\s+[\w.]+' + [regex]::Escape(($entType -replace '^.*\.','')) + '\s*;') } | Select-Object -First 1)
                if (-not $entImport -and $entType -match '\.') { $entImport = "import $entType;" }
                elseif (-not $entImport) { $entImport = "import unknown.entity.$entType;" }
                $entSimple = ($entType -replace '^.*\.','')
                $t = @"
package $pkg;

import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.math.Axis;
$($modelImport.Trim())
$($entImport.Trim())
import net.minecraft.client.renderer.SubmitNodeCollector;
import net.minecraft.client.renderer.entity.EntityRenderer;
import net.minecraft.client.renderer.entity.EntityRendererProvider.Context;
import net.minecraft.client.renderer.entity.state.LivingEntityRenderState;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.client.renderer.texture.OverlayTexture;
import net.minecraft.resources.Identifier;

/** Primer 1.21.2 Entity Render States — mirror ArrowRenderer.submit pattern. */
public class $cls extends EntityRenderer<$entSimple, LivingEntityRenderState> {
   private static final Identifier TEXTURE = Identifier.parse("$texLiteral");
   private final $modelType $modelName;

   public $cls(Context context) {
      super(context);
      this.$modelName = new $modelType(context.bakeLayer($layerExpr));
   }

   @Override
   public LivingEntityRenderState createRenderState() {
      return new LivingEntityRenderState();
   }

   @Override
   public void extractRenderState($entSimple entity, LivingEntityRenderState state, float partialTicks) {
      super.extractRenderState(entity, state, partialTicks);
      state.xRot = entity.getXRot(partialTicks);
      state.yRot = entity.getYRot(partialTicks);
   }

   @Override
   public void submit(LivingEntityRenderState state, PoseStack poseStack, SubmitNodeCollector buffer, CameraRenderState camera) {
      poseStack.pushPose();
      poseStack.mulPose(Axis.YP.rotationDegrees(state.yRot - 90.0F));
      poseStack.mulPose(Axis.ZP.rotationDegrees(90.0F + state.xRot));
      this.$modelName.setupAnim(state);
      buffer.submitModel(this.$modelName, state, poseStack, TEXTURE, state.lightCoords, OverlayTexture.NO_OVERLAY, state.outlineColor, null);
      poseStack.popPose();
      super.submit(state, poseStack, buffer, camera);
   }
}
"@
            }
        }

        # TemptGoal.canUse reads Attributes.TEMPT_RANGE (default 10). Mob.createMobAttributes()
        # does not include it — chestburster tick crash: Can't find attribute minecraft:tempt_range.
        if ($t -match 'new\s+TemptGoal\b' -and $t -match 'createAttributes\s*\(' -and $t -notmatch 'Attributes\.TEMPT_RANGE') {
            $t = [regex]::Replace($t,
                '(public static Builder createAttributes\(\) \{)([\s\S]*?)(\r?\n\s*return builder)',
                {
                    param($mm)
                    if ($mm.Groups[2].Value -match 'TEMPT_RANGE') { return $mm.Value }
                    return ($mm.Groups[1].Value + $mm.Groups[2].Value + "`r`n      builder = builder.add(Attributes.TEMPT_RANGE, 10.0);" + $mm.Groups[3].Value)
                })
        }

        # Projectile models: setupAnim(Entity,...) / multi-arg → setupAnim(LivingEntityRenderState)
        if ($file.Name -match 'Model' -and $t -match 'EntityModel<' -and $t -match 'setupAnim\(' -and $t -match 'Acid|Spit|Projectile|Arrow') {
            $t = $t -replace 'extends\s+EntityModel<\s*Entity\s*>', 'extends EntityModel<net.minecraft.client.renderer.entity.state.LivingEntityRenderState>'
            $t = $t -replace 'extends\s+EntityModel<\s*[\w.]+Entity\s*>', 'extends EntityModel<net.minecraft.client.renderer.entity.state.LivingEntityRenderState>'
            $t = [regex]::Replace($t,
                '(?s)public\s+void\s+setupAnim\s*\([^)]*\)\s*\{.*?\}',
                "public void setupAnim(net.minecraft.client.renderer.entity.state.LivingEntityRenderState entity) {`r`n      // EntityRenderState-driven; pose from extractRenderState`r`n   }")
        }

        if ($t -ne $o) {
            [IO.File]::WriteAllText($file.FullName, $t)
            $touched++
        }
    }

    $gr = Invoke-Minecraft262CustomGameRuleDeferredRegister -Root $Root
    return ($touched + $gr)
}

function Invoke-OptionalIntegrationExcludePass {
    <#
    .SYNOPSIS
      Exclude optional third-party integration sources that are not on the compile classpath
      (Carry On, Sable ragdoll, etc.) so leaf mods can still build.
      When the dependency pipeline already downloaded a matching 26.2 jar into libs/, keep the
      integration sources (do not exclude) so the leaf compiles against that artifact.
    #>
    param([string]$Root)

    $javaRoot = Join-Path $Root 'src\main\java'
    if (-not (Test-Path $javaRoot)) { return 0 }

    $libsDir = Join-Path $Root 'libs'
    $hasLib = {
        param([string]$Needle)
        if (-not (Test-Path -LiteralPath $libsDir)) { return $false }
        return [bool](Get-ChildItem -LiteralPath $libsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $Needle } |
            Select-Object -First 1)
    }

    $softRoots = @(
        'tschipp.carryon',
        'dev.leo.sableplayerragdoll',
        'mezz.jei',
        'squeek.appleskin'
    )
    # Skip exclude when dual-version / target jar was acquired into libs/.
    if (& $hasLib 'jei') { $softRoots = @($softRoots | Where-Object { $_ -ne 'mezz.jei' }) }
    if (& $hasLib 'carryon') { $softRoots = @($softRoots | Where-Object { $_ -ne 'tschipp.carryon' }) }
    if (& $hasLib 'appleskin') { $softRoots = @($softRoots | Where-Object { $_ -ne 'squeek.appleskin' }) }
    if (& $hasLib 'sable') { $softRoots = @($softRoots | Where-Object { $_ -ne 'dev.leo.sableplayerragdoll' }) }

    # Folder-name soft deps (even when the leaf Integration class uses ModList checks / no hard imports).
    $softPathMarkers = @(
        '[\\/]integration[\\/]carryon[\\/]',
        '[\\/]integration[\\/]sable[\\/]',
        '[\\/]integration[\\/]jei[\\/]',
        '[\\/]integration[\\/]appleskin[\\/]',
        # Easy Mob Farm and similar leaf mods put JEI under compat/jei (not integration/jei).
        '[\\/]compat[\\/]jei[\\/]',
        '[\\/]gametest[\\/]'
    )
    if (& $hasLib 'jei') {
        $softPathMarkers = @($softPathMarkers | Where-Object { $_ -notmatch 'jei' })
    }
    if (& $hasLib 'carryon') {
        $softPathMarkers = @($softPathMarkers | Where-Object { $_ -notmatch 'carryon' })
    }
    if (& $hasLib 'appleskin') {
        $softPathMarkers = @($softPathMarkers | Where-Object { $_ -notmatch 'appleskin' })
    }
    if (& $hasLib 'sable') {
        $softPathMarkers = @($softPathMarkers | Where-Object { $_ -notmatch 'sable' })
    }
    $touched = 0
    $integrationDirs = Get-ChildItem $javaRoot -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'integration' -or $_.FullName -match '[\\/]integration[\\/]' }

    foreach ($dir in @($integrationDirs)) {
        $files = Get-ChildItem $dir.FullName -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            $needsSoft = $false
            foreach ($pkg in $softRoots) {
                if ($text -match [regex]::Escape("import $pkg")) { $needsSoft = $true; break }
            }
            if (-not $needsSoft) {
                foreach ($markerRe in $softPathMarkers) {
                    if ($f.FullName -match $markerRe) { $needsSoft = $true; break }
                }
            }
            if (-not $needsSoft) { continue }

            # Prefer excluding via build.gradle; also neutralize file so compile cannot see it
            $rel = $f.FullName.Substring($javaRoot.Length).TrimStart('\','/')
            $marker = Join-Path $Root 'OPTIONAL_INTEGRATIONS_EXCLUDED.txt'
            Add-Content -LiteralPath $marker -Value $rel
            Remove-Item -LiteralPath $f.FullName -Force
            $touched++
        }
    }

    # Always drop GameTest harness sources — annotations are not on the leaf compile classpath
    # (262r soft-dep-exclude; CASE-006 Easy Mob Farm). Delete files + exclude, even when no soft-dep jars missing.
    $javaRootForGt = Join-Path $Root 'src\main\java'
    if (Test-Path -LiteralPath $javaRootForGt) {
        foreach ($gtDir in @(Get-ChildItem -LiteralPath $javaRootForGt -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'gametest' })) {
            foreach ($gf in @(Get-ChildItem -LiteralPath $gtDir.FullName -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $gf.FullName -Force -ErrorAction SilentlyContinue
                $touched++
            }
        }
    }
    $bg = Join-Path $Root 'build.gradle'
    if (Test-Path $bg) {
        $g = [System.IO.File]::ReadAllText($bg)
        $gChanged = $false
        if ($g -notmatch "exclude\s+'?\*\*/gametest/\*\*'?") {
            if ($g -match "(?m)^sourceSets\.main\.java\s*\{") {
                $g = $g -replace "(sourceSets\.main\.java\s*\{)", "`$1`r`n    exclude '**/gametest/**'"
            }
            else {
                $g += "`r`n// GameTest harness not on leaf compile classpath (262r soft-dep-exclude).`r`nsourceSets.main.java {`r`n    exclude '**/gametest/**'`r`n}`r`n"
            }
            $gChanged = $true
        }
        if ($touched -gt 0 -and $g -notmatch 'OPTIONAL_INTEGRATIONS_EXCLUDED') {
            if ($g -match "(?m)^sourceSets\.main\.java\s*\{") {
                # already has java excludes (datagen); append more excludes inside if possible
                if ($g -notmatch "exclude\s+'?\*\*/integration/carryon/\*\*'?") {
                    $g = $g -replace "(sourceSets\.main\.java\s*\{)", "`$1`r`n    exclude '**/integration/carryon/**'`r`n    exclude '**/integration/sable/**'`r`n    exclude '**/compat/jei/**'"
                    $gChanged = $true
                }
            }
            else {
                $g += @"

// Soft-dep integrations removed when companion mods are absent (OPTIONAL_INTEGRATIONS_EXCLUDED.txt).
sourceSets.main.java {
    exclude '**/integration/carryon/**'
    exclude '**/integration/sable/**'
}
"@
                $gChanged = $true
            }
        }
        if ($gChanged) {
            [System.IO.File]::WriteAllText($bg, $g)
        }
    }
    return $touched
}

function Invoke-DfuCodecRepairPass {
    <#
    .SYNOPSIS
      Repair Vineflower DFU / record / mixin artifacts that break RecordCodecBuilder inference.
      1) Explicit RecordCodecBuilder.<T>create / mapCodec type witnesses (fixes Kind1.group inference).
      2) Record component field access inside .validate(...) lambdas: config.limbs -> config.limbs().
      3) Mixin (Target)this -> (Target)(Object)this.
    #>
    param([string]$Root)

    $files = Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue
    $touched = 0
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        $o = $t

        # Explicit type witnesses on RecordCodecBuilder.create / mapCodec assignments.
        $t = [regex]::Replace($t,
            '(?m)(Codec\s*<\s*([A-Za-z_][\w]*)\s*>\s+\w+\s*=\s*RecordCodecBuilder)\.(create)\s*\(',
            '${1}.<$2>$3(')
        $t = [regex]::Replace($t,
            '(?m)(MapCodec\s*<\s*([A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*)*)\s*>\s+\w+\s*=\s*RecordCodecBuilder)\.(mapCodec)\s*\(',
            '${1}.<$2>$3(')
        # Nested record types: Codec<Outer.Inner>
        $t = [regex]::Replace($t,
            '(?m)(Codec\s*<\s*([A-Za-z_][\w]*\.[A-Za-z_][\w]*)\s*>\s+\w+\s*=\s*RecordCodecBuilder)\.(create)\s*\(',
            '${1}.<$2>$3(')

        # Collect record component names in this file.
        $components = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($rm in [regex]::Matches($t, '(?m)\brecord\s+\w+\s*\(([^)]*)\)')) {
            $paramList = $rm.Groups[1].Value
            if (-not $paramList.Trim()) { continue }
            $depth = 0
            $cur = New-Object System.Text.StringBuilder
            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($ch in $paramList.ToCharArray()) {
                if ($ch -eq '<' -or $ch -eq '(') { $depth++ }
                elseif ($ch -eq '>' -or $ch -eq ')') { if ($depth -gt 0) { $depth-- } }
                elseif ($ch -eq ',' -and $depth -eq 0) {
                    $parts.Add($cur.ToString()) | Out-Null
                    [void]$cur.Clear()
                    continue
                }
                [void]$cur.Append($ch)
            }
            if ($cur.Length -gt 0) { $parts.Add($cur.ToString()) | Out-Null }
            foreach ($p in $parts) {
                if ($p -match '(?s)([A-Za-z_][\w]*)\s*$') { [void]$components.Add($matches[1]) }
            }
        }

        # Only rewrite accessors inside balanced .validate( ... ) regions (avoid builder.field damage).
        if ($components.Count -gt 0) {
            $sb = New-Object System.Text.StringBuilder
            $i = 0
            while ($i -lt $t.Length) {
                $idx = $t.IndexOf('.validate(', $i)
                if ($idx -lt 0) { [void]$sb.Append($t.Substring($i)); break }
                [void]$sb.Append($t.Substring($i, $idx - $i))
                $startArgs = $idx + '.validate('.Length
                $depth = 1
                $j = $startArgs
                while ($j -lt $t.Length -and $depth -gt 0) {
                    $c = $t[$j]
                    if ($c -eq '(') { $depth++ }
                    elseif ($c -eq ')') { $depth-- }
                    $j++
                }
                $body = $t.Substring($startArgs, ($j - 1) - $startArgs)
                foreach ($comp in @($components)) {
                    $rx = [regex]::new("(?<![\w.])([a-z_][\w]*)\.$([regex]::Escape($comp))\b(?!\s*\()")
                    $body = $rx.Replace($body, {
                            param($mm)
                            $recv = $mm.Groups[1].Value
                            if ($recv -eq 'this' -or $recv -eq 'super') { return $mm.Value }
                            return ($recv + '.' + $comp + '()')
                        })
                }
                [void]$sb.Append('.validate(')
                [void]$sb.Append($body)
                [void]$sb.Append(')')
                $i = $j
            }
            $t = $sb.ToString()
        }

        # Mixin: (LivingEntity)this -> (LivingEntity)(Object)this
        if ($t -match '@Mixin\b') {
            $t = [regex]::Replace($t, '\(\s*([A-Za-z_][\w]*)\s*\)\s*this\b', '($1)(Object)this')
            $t = $t -replace '\((\w+)\)\(Object\)\(Object\)this\b', '($1)(Object)this'
            $t = $t -replace '\(Object\)\(Object\)this\b', '(Object)this'
        }

        # CheckerFramework annotations often lack the dependency on decompiled trees
        $t = $t -replace 'import\s+org\.checkerframework\.checker\.nullness\.qual\.[^;]+;\r?\n', ''
        $t = $t -replace '@NonNull\b\s*', ''

        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $touched++
        }
    }
    return $touched
}

function Invoke-Mcreator1218ToNeoForge262Pass {
    <#
    .SYNOPSIS
      MCreator / NeoForge 1.21.x jar decompile lessons (MOAdecor BATH etc.) for Minecraft 26.2.
      Bulk-safe transforms: fluid overlay stubs, noCollision, client GUI extract API, isClientSide(),
      removed Tuple, and broken ItemHandler capability lookups.
    #>
    param([string]$Root)

    $files = Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue
    $touched = 0
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        $o = $t

        # --- BlockBehaviour spelling (1.21.x British / old mapping) ---
        $t = $t -replace '\.noCollission\(\)', '.noCollision()'

        # --- Forge fluid overlay on Block (method no longer on Block in 26.2) ---
        # Drop entire method body; decorative MCreator blocks always returned true.
        $t = [regex]::Replace($t,
            '(?ms)^\s*(?:@Override\s*)?public\s+boolean\s+shouldDisplayFluidOverlay\s*\([^)]*\)\s*\{(?:[^{}]|\{[^{}]*\})*\}\s*',
            '')
        $t = $t -replace 'import\s+net\.minecraft\.world\.level\.BlockAndTintGetter\s*;\s*\r?\n', ''
        # Client-only type lives under renderer.block in 26.2 (if any remaining refs)
        $t = $t -replace 'net\.minecraft\.world\.level\.BlockAndTintGetter',
            'net.minecraft.client.renderer.block.BlockAndTintGetter'

        # --- Level.isClientSide field is private; always call method ---
        $t = [regex]::Replace($t, '\.isClientSide\b(?!\s*\()', '.isClientSide()')

        # --- GuiGraphics -> GuiGraphicsExtractor (26.x extract pipeline) ---
        $t = [regex]::Replace($t, '\bGuiGraphics\b(?!Extractor)', 'GuiGraphicsExtractor')
        $t = $t -replace 'import\s+net\.minecraft\.client\.gui\.GuiGraphicsExtractor\s*;',
            'import net.minecraft.client.gui.GuiGraphicsExtractor;'
        $t = $t -replace 'import\s+net\.minecraft\.client\.gui\.GuiGraphics\s*;',
            'import net.minecraft.client.gui.GuiGraphicsExtractor;'

        # Common Screen method renames used by MCreator container screens
        $t = $t -replace '\bprotected\s+void\s+renderBg\s*\(', 'public void extractBackground('
        $t = $t -replace '\bpublic\s+void\s+renderBg\s*\(', 'public void extractBackground('
        $t = $t -replace '\.renderTooltip\s*\(', '.extractTooltip('
        $t = $t -replace '\bprotected\s+void\s+renderLabels\s*\(', 'protected void extractLabels('
        $t = $t -replace '\bpublic\s+void\s+renderLabels\s*\(', 'public void extractLabels('
        # render(...) that was the old Screen render hook often becomes extractRenderState
        $t = [regex]::Replace($t,
            '(?m)^(\s*)public\s+void\s+render\s*\(\s*GuiGraphicsExtractor\s+',
            '$1public void extractRenderState(GuiGraphicsExtractor ')

        # imageWidth/imageHeight are final ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â pass size into super(...)
        # Immediate form: super(...); this.imageWidth = W; this.imageHeight = H;
        $t = [regex]::Replace($t,
            'super\(([^;]+?)\);\s*this\.imageWidth\s*=\s*(\d+)\s*;\s*this\.imageHeight\s*=\s*(\d+)\s*;',
            'super($1, $2, $3);')
        # MCreator form: super(...); field assigns...; this.imageWidth = W; this.imageHeight = H;
        $t = [regex]::Replace($t,
            'super\((\s*\w+\s*,\s*\w+\s*,\s*\w+\s*)\);((?:\s*this\.\w+\s*=\s*[^;]+;){0,8})\s*this\.imageWidth\s*=\s*(\d+)\s*;\s*this\.imageHeight\s*=\s*(\d+)\s*;',
            'super($1, $3, $4);$2')

        # Drop trivial extractRenderState that only calls super + extractTooltip (base already does this)
        $t = [regex]::Replace($t,
            '(?ms)^\s*(?:@Override\s*)?public\s+void\s+extractRenderState\s*\(\s*GuiGraphicsExtractor\s+\w+\s*,\s*int\s+\w+\s*,\s*int\s+\w+\s*,\s*float\s+\w+\s*\)\s*\{\s*super\.(?:extractRenderState|render)\([^;]+;\s*this\.extractTooltip\([^;]+;\s*\}\s*',
            '')

        # Fix extractBackground arg order if still (graphics, float, int, int) from old renderBg
        $t = [regex]::Replace($t,
            '(public|protected)\s+void\s+extractBackground\s*\(\s*GuiGraphicsExtractor\s+(\w+)\s*,\s*float\s+(\w+)\s*,\s*int\s+(\w+)\s*,\s*int\s+(\w+)\s*\)',
            '$1 void extractBackground(GuiGraphicsExtractor $2, int $4, int $5, float $3)')

        # Mel/MCreator 1.21.4 screens on 26.2: strip removed RenderSystem blend/color; blit pipeline; text(); client packets
        $t = [regex]::Replace($t, '(?m)^\s*RenderSystem\.(setShaderColor|enableBlend|disableBlend|defaultBlendFunc)\([^;]*\);\s*\r?\n', '')
        $t = $t -replace '(?m)^\s*RenderSystem\.[^;]+;\s*\r?\n', ''
        $t = $t.Replace('RenderType::guiTextured', 'net.minecraft.client.renderer.RenderPipelines.GUI_TEXTURED')
        $t = $t -replace 'import\s+net\.minecraft\.client\.renderer\.rendertype\.RenderTypes;\r?\n', ''
        $t = $t -replace 'import\s+com\.mojang\.blaze3d\.systems\.RenderSystem;\r?\n', ''
        $t = [regex]::Replace($t, 'guiGraphics\.drawString\s*\(', 'guiGraphics.text(')
        $t = $t -replace 'ClientClientPacketDistributor', 'ClientPacketDistributor'
        if ($t -match '(?<!Client)PacketDistributor\.sendToServer') {
            $t = [regex]::Replace($t, '(?<!Client)PacketDistributor\.sendToServer', 'ClientPacketDistributor.sendToServer')
            # Keep PacketDistributor import when sendToPlayer (server) remains
            if ($t -match '(?<!\w)PacketDistributor\.sendToPlayer') {
                if ($t -notmatch 'import\s+net\.neoforged\.neoforge\.client\.network\.ClientPacketDistributor;') {
                    $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.client.network.ClientPacketDistributor;`r`n", 1)
                }
                if ($t -notmatch 'import\s+net\.neoforged\.neoforge\.network\.PacketDistributor;') {
                    $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.network.PacketDistributor;`r`n", 1)
                }
            }
            else {
                $t = $t -replace 'import\s+net\.neoforged\.neoforge\.network\.PacketDistributor;', 'import net.neoforged.neoforge.client.network.ClientPacketDistributor;'
                if ($t -notmatch 'import\s+net\.neoforged\.neoforge\.client\.network\.ClientPacketDistributor;') {
                    $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.client.network.ClientPacketDistributor;`r`n", 1)
                }
            }
        }
        elseif ($t -match '(?<!\w)PacketDistributor\.sendToPlayer' -and $t -notmatch 'import\s+net\.neoforged\.neoforge\.network\.PacketDistributor;') {
            $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.network.PacketDistributor;`r`n", 1)
        }
        # Switch-expression: yield ...; break; is illegal
        $t = [regex]::Replace($t, '(?m)^(\s*yield\s+[^;]+;)\s*\r?\n\s*break\s*;\s*$', '$1')
        # 26.2 emissiveRendering is Predicate<BlockState>
        $t = [regex]::Replace($t, '\.emissiveRendering\s*\(\s*\(\s*(\w+)\s*,\s*\w+\s*,\s*\w+\s*\)\s*->', '.emissiveRendering(($1) ->')
        # GameProfile / weather / Optional NBT via copyTag / CHAIN mangling leftovers
        $t = $t.Replace('.getGameProfile().getId()', '.getGameProfile().id()')
        $t = [regex]::Replace($t, '(\w+)\.getLevelData\(\)\.isRaining(?:At)?\(\)', '($1 instanceof net.minecraft.world.level.Level __lvlRain && __lvlRain.isRaining())')
        $t = [regex]::Replace($t, '(\w+)\.getLevelData\(\)\.isThundering\(\)', '($1 instanceof net.minecraft.world.level.Level __lvlThunder && __lvlThunder.isThundering())')
        $t = $t.Replace('MelsDecoModBlocks.IRON_CHAIN_LINK_FENCE', 'MelsDecoModBlocks.CHAIN_LINK_FENCE')
        $t = $t.Replace('MelsDecoModItems.IRON_CHAIN_LINK_FENCE', 'MelsDecoModItems.CHAIN_LINK_FENCE')
        $t = $t.Replace('MelsDecoModBlocks.IRON_CHAINSAW', 'MelsDecoModBlocks.CHAINSAW')
        $t = $t.Replace('MelsDecoModItems.IRON_CHAINSAW_ITEM', 'MelsDecoModItems.CHAINSAW_ITEM')
        $t = $t.Replace('MelsDecoModItems.IRON_CHAINSAW', 'MelsDecoModItems.CHAINSAW')
        $t = [regex]::Replace($t, '\.copyTag\(\)\s*\r?\n?\s*\.getDouble\(([^)]+)\)', '.copyTag().getDoubleOr($1, Double.NaN)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\.getDouble\(([^)]+)\)', '.copyTag().getDoubleOr($1, Double.NaN)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\s*\r?\n?\s*\.getBoolean\(([^)]+)\)', '.copyTag().getBooleanOr($1, false)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\.getBoolean\(([^)]+)\)', '.copyTag().getBooleanOr($1, false)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\s*\r?\n?\s*\.getInt\(([^)]+)\)', '.copyTag().getIntOr($1, 0)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\.getInt\(([^)]+)\)', '.copyTag().getIntOr($1, 0)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\s*\r?\n?\s*\.getString\(([^)]+)\)', '.copyTag().getStringOr($1, "")')
        $t = [regex]::Replace($t, '\.copyTag\(\)\.getString\(([^)]+)\)', '.copyTag().getStringOr($1, "")')
        # PersistentData Optional accessors (Mel block NBT helpers)
        $t = $t -replace '\.getPersistentData\(\)\.getBoolean\(([^)]+)\)', '.getPersistentData().getBooleanOr($1, false)'
        $t = $t -replace '\.getPersistentData\(\)\.getString\(([^)]+)\)', '.getPersistentData().getStringOr($1, "")'
        $t = $t -replace '\.getPersistentData\(\)\.getInt\(([^)]+)\)', '.getPersistentData().getIntOr($1, 0)'
        $t = $t -replace '\.getPersistentData\(\)\.getDouble\(([^)]+)\)', '.getPersistentData().getDoubleOr($1, 0.0)'
        # BlockEntity.loadWithComponents(CompoundTag, RegistryAccess) -> ValueInput
        if ($t -match '\.loadWithComponents\s*\(\s*\w+\s*,') {
            $t = [regex]::Replace($t,
                '\.loadWithComponents\s*\(\s*(\w+)\s*,\s*([^)]+?)\.registryAccess\(\)\s*\)',
                '.loadWithComponents(TagValueInput.create(ProblemReporter.DISCARDING, $2.registryAccess(), $1))')
            if ($t -match '\bTagValueInput\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.level\.storage\.TagValueInput\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                    "`$1`r`nimport net.minecraft.util.ProblemReporter;`r`nimport net.minecraft.world.level.storage.TagValueInput;`r`n", 1)
            }
        }
        # Item tooltip / hurtEnemy / inventoryTick (Mel cosmetics)
        if ($t -match 'void\s+appendHoverText\s*\(\s*ItemStack\s+\w+\s*,\s*TooltipContext\s+\w+\s*,\s*List<\s*Component\s*>') {
            if ($t -notmatch 'import\s+java\.util\.function\.Consumer;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport java.util.function.Consumer;`r`nimport net.minecraft.world.item.component.TooltipDisplay;`r`n", 1)
            }
            $t = [regex]::Replace($t,
                'void\s+appendHoverText\s*\(\s*ItemStack\s+(\w+)\s*,\s*TooltipContext\s+(\w+)\s*,\s*List<\s*Component\s*>\s+(\w+)\s*,\s*TooltipFlag\s+(\w+)\s*\)',
                'void appendHoverText(ItemStack $1, TooltipContext $2, TooltipDisplay display, Consumer<Component> $3, TooltipFlag $4)')
            $t = [regex]::Replace($t,
                'super\.appendHoverText\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)',
                'super.appendHoverText($1, $2, display, $3, $4)')
            $t = [regex]::Replace($t, '\b(\w+)\.add\((Component\.[^;]+)\)', '$1.accept($2)')
        }
        $t = [regex]::Replace($t,
            'public\s+boolean\s+hurtEnemy\s*\(\s*ItemStack\s+(\w+)\s*,\s*LivingEntity\s+(\w+)\s*,\s*LivingEntity\s+(\w+)\s*\)',
            'public void hurtEnemy(ItemStack $1, LivingEntity $2, LivingEntity $3)')
        # void hurtEnemy must not return boolean leftovers
        $t = [regex]::Replace($t,
            '(public\s+void\s+hurtEnemy\s*\([^)]*\)\s*\{(?:[^{}]|\{[^{}]*\})*?)return\s+(?:true|false)\s*;',
            '$1')
        $t = $t.Replace('LivingEntity.getSlotForHand(entity.getUsedItemHand())', 'entity.getUsedItemHand().asEquipmentSlot()')
        $t = [regex]::Replace($t,
            'public\s+void\s+inventoryTick\s*\(\s*ItemStack\s+(\w+)\s*,\s*Level\s+(\w+)\s*,\s*Entity\s+(\w+)\s*,\s*int\s+(\w+)\s*,\s*boolean\s+(\w+)\s*\)',
            'public void inventoryTick(ItemStack $1, net.minecraft.server.level.ServerLevel $2, Entity $3, net.minecraft.world.entity.EquipmentSlot $4)')
        # Capture 4th arg name (slot); prior bug used literal $4 with only 3 groups
        $t = [regex]::Replace($t,
            'super\.inventoryTick\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*\w+\s*\)',
            'super.inventoryTick($1, $2, $3, $4)')
        $t = $t -replace 'super\.inventoryTick\(([^,]+),\s*([^,]+),\s*([^,]+),\s*\$4\)', 'super.inventoryTick($1, $2, $3, slot)'
        # Armor worn check: getArmorSlots / bad getEquippedSlots -> explicit armor slots List
        $armorWorn = 'java.util.List.of($1.getItemBySlot(net.minecraft.world.entity.EquipmentSlot.HEAD), $1.getItemBySlot(net.minecraft.world.entity.EquipmentSlot.CHEST), $1.getItemBySlot(net.minecraft.world.entity.EquipmentSlot.LEGS), $1.getItemBySlot(net.minecraft.world.entity.EquipmentSlot.FEET)).contains($2)'
        $t = [regex]::Replace($t,
            'Iterables\.contains\(\s*(\w+)\.getArmorSlots\(\)\s*,\s*(\w+)\s*\)',
            $armorWorn)
        $t = [regex]::Replace($t,
            'Iterables\.contains\(\s*(\w+)\.getEquippedSlots\s*\(\s*net\.minecraft\.world\.entity\.EquipmentSlotGroup\.ARMOR\s*\)\s*,\s*(\w+)\s*\)',
            $armorWorn)
        $t = $t.Replace('.getArmorSlots()', '.getEquippedSlots(net.minecraft.world.entity.EquipmentSlotGroup.ARMOR)')
        # ItemModel / RangeSelect: LivingEntity owner arg -> ItemOwner (26.2)
        if ($t -match 'RangeSelectItemModelProperty|implements\s+ItemModel\b|LegacyOverrideSelectItemModel') {
            $t = [regex]::Replace($t,
                '(public\s+float\s+get\s*\(\s*ItemStack\s+\w+\s*,\s*@Nullable\s+ClientLevel\s+\w+\s*,\s*@Nullable\s+)LivingEntity(\s+)(\w+)(\s*,\s*int\s+\w+\s*\))',
                '${1}ItemOwner${2}${3}${4}')
            $t = $t -replace '@Nullable LivingEntity entity', '@Nullable ItemOwner entity'
            $t = $t -replace '@Nullable LivingEntity var3', '@Nullable ItemOwner var3'
            # SprayPaint-style: execute(LivingEntity) needs asLivingEntity()
            if ($t -notmatch 'DisplaySprayPaintDesignItemProcedure\.execute\([^)]*asLivingEntity') {
                $t = [regex]::Replace($t,
                    'DisplaySprayPaintDesignItemProcedure\.execute\((\w+)\)',
                    'DisplaySprayPaintDesignItemProcedure.execute($1 != null ? $1.asLivingEntity() : null)')
            }
            # ConditionalItemModelProperty.get still wants LivingEntity
            $t = $t.Replace(
                'this.property.get(itemStack, level, entity, seed, displayContext)',
                'this.property.get(itemStack, level, entity == null ? null : entity.asLivingEntity(), seed, displayContext)')
            if ($t -match '\bItemOwner\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.entity\.ItemOwner\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                    "`$1`r`nimport net.minecraft.world.entity.ItemOwner;`r`n", 1)
            }
        }
        $t = [regex]::Replace($t, '\.getType\(\)\.is\(([^)]+)\)', '.getType().builtInRegistryHolder().is($1)')
        # ItemModel.Unbaked.bake gained Matrix4fc in 26.2
        $t = [regex]::Replace($t, 'public\s+ItemModel\s+bake\s*\(\s*BakingContext\s+(\w+)\s*\)(\s*\{)', 'public ItemModel bake(BakingContext $1, org.joml.Matrix4fc transformation)$2')
        $t = [regex]::Replace($t, '(\.model|\.fallback)\.bake\((\w+)\)', '$1.bake($2, transformation)')

        # keyPressed(int,int,int) -> KeyEvent (ESC close handled by Screen; keep override when custom)
        if ($t -match 'boolean\s+keyPressed\s*\(\s*int\s+\w+\s*,\s*int\s+\w+\s*,\s*int\s+\w+\s*\)') {
            if ($t -notmatch 'import\s+net\.minecraft\.client\.input\.KeyEvent\s*;') {
                if ($t -match '(?m)^package\s+[^;]+;') {
                    $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                        "`$1`r`nimport net.minecraft.client.input.KeyEvent;`r`n", 1)
                }
            }
            # Simple ESC close pattern from MCreator
            $t = [regex]::Replace($t,
                '(?ms)public\s+boolean\s+keyPressed\s*\(\s*int\s+(\w+)\s*,\s*int\s+\w+\s*,\s*int\s+\w+\s*\)\s*\{\s*if\s*\(\s*\1\s*==\s*256\s*\)\s*\{\s*this\.minecraft\.player\.closeContainer\(\)\s*;\s*return\s+true\s*;\s*\}\s*else\s*\{\s*return\s+super\.keyPressed\s*\(\s*\1\s*,\s*\w+\s*,\s*\w+\s*\)\s*;\s*\}\s*\}',
                @'
public boolean keyPressed(KeyEvent event) {
      if (event.key() == 256) {
         this.minecraft.player.closeContainer();
         return true;
      } else {
         return super.keyPressed(event);
      }
   }
'@)
            # Any remaining 3-arg keyPressed calls to super
            $t = [regex]::Replace($t,
                'super\.keyPressed\s*\(\s*(\w+)\s*,\s*\w+\s*,\s*\w+\s*\)',
                'super.keyPressed(event)')
            $t = [regex]::Replace($t,
                'public\s+boolean\s+keyPressed\s*\(\s*int\s+\w+\s*,\s*int\s+\w+\s*,\s*int\s+\w+\s*\)',
                'public boolean keyPressed(KeyEvent event)')
        }

        # --- net.minecraft.util.Tuple removed: MCreator delayed work queue ---
        if ($t -match 'net\.minecraft\.util\.Tuple' -or $t -match '\bTuple\s*<\s*Runnable') {
            $t = $t -replace 'import\s+net\.minecraft\.util\.Tuple\s*;\s*\r?\n', ''
            $t = $t -replace 'Collection<\s*Tuple<\s*Runnable\s*,\s*Integer\s*>\s*>', 'Collection<Object[]>'
            $t = $t -replace 'List<\s*Tuple<\s*Runnable\s*,\s*Integer\s*>\s*>', 'List<Object[]>'
            $t = $t -replace 'new\s+Tuple\s*(?:<\s*Runnable\s*,\s*Integer\s*>)?\s*\(\s*([^,]+)\s*,\s*([^)]+)\)', 'new Object[] { $1, $2 }'
            $t = $t -replace '\(Tuple<\s*Runnable\s*,\s*Integer\s*>\)\s*', ''
            # work.setB((Integer)work.getB() - 1)
            $t = [regex]::Replace($t,
                '(\w+)\.setB\(\s*\(Integer\)\1\.getB\(\)\s*-\s*1\s*\)',
                '$1[1] = (Integer)$1[1] - 1')
            $t = [regex]::Replace($t, '\(Integer\)(\w+)\.getB\(\)', '(Integer)$1[1]')
            $t = [regex]::Replace($t, '\(\(Runnable\)(\w+)\.getA\(\)\)', '((Runnable)$1[0])')
            $t = [regex]::Replace($t, '(\w+)\.getA\(\)', '$1[0]')
            $t = [regex]::Replace($t, '(\w+)\.getB\(\)', '$1[1]')
        }

        # --- ItemHandler.ITEM / .ENTITY capability symbols (1.21 MCreator menus) ---
        # Capabilities.Item now uses ResourceHandler + ItemAccess; skip transfer binding and keep ItemStackHandler.
        if ($t -match 'ItemHandler\.(ITEM|ENTITY|BLOCK)\b') {
            # Item stack capability bind block
            $nl = [Environment]::NewLine
            $t = [regex]::Replace($t,
                '(?ms)IItemHandler\s+cap\s*=\s*\(IItemHandler\)\s*itemstack\.getCapability\s*\(\s*ItemHandler\.ITEM\s*\)\s*;\s*if\s*\(\s*cap\s*!=\s*null\s*\)\s*\{\s*this\.internal\s*=\s*cap\s*;\s*this\.bound\s*=\s*true\s*;\s*\}',
                ("// 26.2: Capabilities.Item.ITEM needs ItemAccess/transfer API - keep ItemStackHandler" + $nl + "            this.bound = true;"))
            # Entity capability bind block
            $t = [regex]::Replace($t,
                '(?ms)IItemHandler\s+cap\s*=\s*\(IItemHandler\)\s*this\.boundEntity\.getCapability\s*\(\s*ItemHandler\.ENTITY\s*\)\s*;\s*if\s*\(\s*cap\s*!=\s*null\s*\)\s*\{\s*this\.internal\s*=\s*cap\s*;\s*this\.bound\s*=\s*true\s*;\s*\}',
                ("// 26.2: Capabilities.Item.ENTITY transfer rewrite skipped - keep ItemStackHandler" + $nl + "               this.bound = true;"))
            # Leftover bare references
            $t = $t -replace 'ItemHandler\.ITEM', '/* ItemHandler.ITEM removed */ null'
            $t = $t -replace 'ItemHandler\.ENTITY', '/* ItemHandler.ENTITY removed */ null'
            $t = $t -replace 'ItemHandler\.BLOCK', '/* ItemHandler.BLOCK removed */ null'
        }

        # --- Clean unused FluidState import only when file no longer references FluidState ---
        if ($t -notmatch '\bFluidState\b' -and $t -match 'import\s+net\.minecraft\.world\.level\.material\.FluidState\s*;') {
            $t = $t -replace 'import\s+net\.minecraft\.world\.level\.material\.FluidState\s*;\s*\r?\n', ''
        }

        # --- Minecraft.screen field moved to gui.screen() in 26.2 ---
        # MCreator queueServerWork is drained on ServerTickEvent. Client entity ticks must not enqueue
        # lambdas that captured ClientLevel (C2ME: ThreadLocalRandom owner Render thread vs Server thread).
        if ($t -match 'void\s+queueServerWork\s*\(\s*int' -and $t -notmatch 'ServerLifecycleHooks\.getCurrentServer') {
            $t = $t -replace '(public static void queueServerWork\(int tick, Runnable action\) \{\s*)(workQueue\.add)',
                "`$1net.minecraft.server.MinecraftServer _srv = net.neoforged.neoforge.server.ServerLifecycleHooks.getCurrentServer();`r`n      if (_srv == null || !_srv.isSameThread()) { return; }`r`n      `$2"
        }

        $t = $t -replace 'Minecraft\.getInstance\(\)\.screen\b', 'Minecraft.getInstance().gui.screen()'
        $t = $t -replace '(?<![\w.])minecraft\.screen\b', 'minecraft.gui.screen()'

        # --- DeferredRegister.Items.registerItem(..., Properties) needs Supplier/UnaryOperator ---
        # Repair broken form produced by naive rewrite (nested BlockItem prop mistaken for registerItem 3rd arg):
        #   new BlockItem(block, () -> prop)  ->  new BlockItem(block, prop)
        $t = $t -replace 'new\s+BlockItem\(([^,]+),\s*\(\)\s*->\s*prop\)', 'new BlockItem($1, prop)'
        # MCreator block helper line: registerItem(path, prop -> new BlockItem(..., prop), properties)
        # wrap only the final Properties variable as a supplier.
        $t = [regex]::Replace($t,
            '(?m)(\.registerItem\([^\n]+,\s*prop\s*->\s*new\s+BlockItem\([^\n]+,\s*prop\))\s*,\s*(\w+)\s*\)\s*;',
            {
                param($m)
                $head = $m.Groups[1].Value
                $props = $m.Groups[2].Value
                if ($props -eq 'prop') { return $m.Value }
                if ($m.Value -match ',\s*\(\)\s*->') { return $m.Value }
                "$head, () -> $props);"
            })

        # --- Payload registrar: StreamCodec<? extends FriendlyByteBuf -> ? super RegistryFriendlyByteBuf ---
        $t = $t -replace 'StreamCodec<\s*\?\s*extends\s+FriendlyByteBuf\s*,', 'StreamCodec<? super RegistryFriendlyByteBuf,'
        if ($t -match 'RegistryFriendlyByteBuf' -and $t -notmatch 'import\s+net\.minecraft\.network\.RegistryFriendlyByteBuf\s*;') {
            if ($t -match 'import\s+net\.minecraft\.network\.FriendlyByteBuf\s*;') {
                $t = $t -replace 'import\s+net\.minecraft\.network\.FriendlyByteBuf\s*;',
                    "import net.minecraft.network.FriendlyByteBuf;`r`nimport net.minecraft.network.RegistryFriendlyByteBuf;"
            }
            elseif ($t -match '(?m)^package\s+[^;]+;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                    "`$1`r`nimport net.minecraft.network.RegistryFriendlyByteBuf;`r`n", 1)
            }
        }
        # NeoForge 26.2: 3-arg playBidirectional leaves client handler null and crashes:
        # "Some clientbound payloads are missing client-side handlers"
        # Only rewrite the exact MCreator 3-arg form:
        #   playBidirectional(id, networkMessage.reader(), networkMessage.handler())
        # Do NOT match partial 4-arg lines or method calls mid-argument (that produced broken
        # "handler(, handler(), handler())" syntax on MOA Electronics).
        $t = $t -replace '\.playBidirectional\(\s*(\w+)\s*,\s*(\w+)\.reader\(\)\s*,\s*(\w+)\.handler\(\)\s*\)', '.playBidirectional($1, $2.reader(), $3.handler(), $3.handler())'
        # Also repair already-corrupted form from older converter builds:
        $t = $t -replace '\.playBidirectional\(\s*(\w+)\s*,\s*(\w+)\.reader\(\)\s*,\s*(\w+)\.handler\(\s*,\s*\3\.handler\(\)\s*,\s*\3\.handler\(\)\s*\)\s*\)', '.playBidirectional($1, $2.reader(), $3.handler(), $3.handler())'

        # MCreator main-mod class: forEach wildcards cannot infer playBidirectional (3-arg or 4-arg).
        if ($t -match 'MESSAGES\.forEach\s*\(\s*\(\s*id\s*,\s*networkMessage\s*\)\s*->\s*registrar\.playBidirectional' -and $t -notmatch 'void\s+registerOne\s*\(') {
            $classMatch = [regex]::Match($t, 'public\s+class\s+(\w+)')
            $className = if ($classMatch.Success) { $classMatch.Groups[1].Value } else { 'ModMain' }
            $t = [regex]::Replace($t,
                'MESSAGES\.forEach\s*\(\s*\(\s*id\s*,\s*networkMessage\s*\)\s*->\s*registrar\.playBidirectional\s*\([^;]*?\)\s*\)\s*;',
                "for (var entry : MESSAGES.entrySet()) {`r`n         registerOne(registrar, entry.getKey(), entry.getValue());`r`n      }")
            if ($t -match 'networkingRegistered\s*=\s*true' -and $t -notmatch 'void\s+registerOne\s*\(') {
                $helper = @"

   `@SuppressWarnings("unchecked")
   private static <T extends CustomPacketPayload> void registerOne(
      PayloadRegistrar registrar, Type<?> id, $className.NetworkMessage<?> message
   ) {
      IPayloadHandler<T> handler = (IPayloadHandler<T>)message.handler();
      registrar.playBidirectional(
         (Type<T>)id,
         (StreamCodec<? super RegistryFriendlyByteBuf, T>)message.reader(),
         handler,
         handler
      );
   }
"@
                $t = [regex]::Replace($t, '(networkingRegistered\s*=\s*true\s*;)(\s*\})', "`$1`$2`r`n$helper", 1)
            }
        }

        # SavedDataType first arg is Identifier in 26.2 (MCreator 1.21.x passed a String)
        $t = [regex]::Replace($t,
            'new\s+SavedDataType(?:<>)?\s*\(\s*"([^"]+)"\s*,',
            'new SavedDataType(Identifier.parse("$1"),')
        # SavedData codec lambdas: ctx is ServerLevel in 26.2, not a HolderLookup context
        $t = $t -replace '\.read\(\s*tag\s*,\s*ctx\.levelOrThrow\(\)\.registryAccess\(\)\s*\)', '.read(tag, null)'
        $t = $t -replace '\.save\(\s*new\s+CompoundTag\(\)\s*,\s*ctx\.levelOrThrow\(\)\.registryAccess\(\)\s*\)', '.save(new CompoundTag(), null)'

        # MoveControl.Operation is protected in 26.2 — hasWanted() is the public MOVE_TO check
        $t = $t -replace 'import\s+net\.minecraft\.world\.entity\.ai\.control\.MoveControl\.Operation\s*;\s*\r?\n', ''
        $t = $t -replace 'this\.operation\s*==\s*Operation\.MOVE_TO', 'this.hasWanted()'
        $t = $t -replace 'this\.operation\s*==\s*MoveControl\.Operation\.MOVE_TO', 'this.hasWanted()'

        # MCreator entity methods inject `entity` locals that do not exist on `this`
        $t = [regex]::Replace($t,
            '(?m)^(\s*)double x = entity\.getX\(\);\s*\r?\n\s*double y = entity\.getY\(\);\s*\r?\n\s*double z = entity\.getZ\(\);\s*\r?\n\s*Level world = entity\.level\(\);',
            '$1double x = this.getX();' + "`r`n" + '$1double y = this.getY();' + "`r`n" + '$1double z = this.getZ();' + "`r`n" + '$1Level world = this.level();')

        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $touched++
        }
    }
    return $touched
}

function Invoke-McreatorForge1201ResiduePass {
    <#
    .SYNOPSIS
      MCreator Forge 1.20.1 leftovers after SRG remap: overlay blit, food builder,
      SavedData 26.2, mob effects, animation factory, NBT Optional accessors.
      Names verified from mcp_config-1.20.1 joined.tsrg + Mojang 1.20.1 mappings.
    #>
    param([string]$Root)

    $files = Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue
    $touched = 0
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        $o = $t

        # FoodProperties 26.2 builder
        $t = $t -replace '\.saturationMod\(', '.saturationModifier('
        $t = $t -replace '\.alwaysEat\(', '.alwaysEdible('
        $t = $t -replace '\.meat\(\)', ''

        # RenderGuiEvent.Pre has no getWindow(); Window is on Minecraft
        $t = $t -replace 'event\.getWindow\(\)', 'Minecraft.getInstance().getWindow()'
        # 26.2 GuiGraphicsExtractor.blit requires a RenderPipeline
        $t = $t -replace 'getGuiGraphics\(\)\.blit\(Identifier\.parse\(', 'getGuiGraphics().blit(net.minecraft.client.renderer.RenderPipelines.GUI_TEXTURED, Identifier.parse('
        $t = $t -replace '(?m)^\s*RenderSystem\.[^;]+;\s*\r?\n', ''
        # Mel/MCreator 1.21.x screens: blit(RenderType::guiTextured, ...) + drawString + PacketDistributor.sendToServer
        $t = $t.Replace('RenderType::guiTextured', 'net.minecraft.client.renderer.RenderPipelines.GUI_TEXTURED')
        $t = $t -replace 'import\s+net\.minecraft\.client\.renderer\.rendertype\.RenderTypes;\r?\n', ''
        $t = $t -replace 'import\s+com\.mojang\.blaze3d\.systems\.RenderSystem;\r?\n', ''
        $t = [regex]::Replace($t, 'guiGraphics\.drawString\s*\(', 'guiGraphics.text(')
        $t = $t -replace 'ClientClientPacketDistributor', 'ClientPacketDistributor'
        if ($t -match '(?<!Client)PacketDistributor\.sendToServer') {
            $t = [regex]::Replace($t, '(?<!Client)PacketDistributor\.sendToServer', 'ClientPacketDistributor.sendToServer')
            if ($t -match '(?<!\w)PacketDistributor\.sendToPlayer') {
                if ($t -notmatch 'import\s+net\.neoforged\.neoforge\.client\.network\.ClientPacketDistributor;') {
                    $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.client.network.ClientPacketDistributor;`r`n", 1)
                }
                if ($t -notmatch 'import\s+net\.neoforged\.neoforge\.network\.PacketDistributor;') {
                    $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.network.PacketDistributor;`r`n", 1)
                }
            }
            else {
                $t = $t -replace 'import\s+net\.neoforged\.neoforge\.network\.PacketDistributor;', 'import net.neoforged.neoforge.client.network.ClientPacketDistributor;'
                if ($t -notmatch 'import\s+net\.neoforged\.neoforge\.client\.network\.ClientPacketDistributor;') {
                    $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.client.network.ClientPacketDistributor;`r`n", 1)
                }
            }
        }
        elseif ($t -match '(?<!\w)PacketDistributor\.sendToPlayer' -and $t -notmatch 'import\s+net\.neoforged\.neoforge\.network\.PacketDistributor;') {
            $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.network.PacketDistributor;`r`n", 1)
        }
        # Switch-expression cleanup: yield ...; break; is illegal
        $t = [regex]::Replace($t, '(?m)^(\s*yield\s+[^;]+;)\s*\r?\n\s*break\s*;\s*$', '$1')
        # GameProfile / weather / CHAIN_LINK mangling leftovers / copyTag Optional NBT
        $t = $t.Replace('.getGameProfile().getId()', '.getGameProfile().id()')
        $t = [regex]::Replace($t, '(\w+)\.getLevelData\(\)\.isRaining(?:At)?\(\)', '($1 instanceof net.minecraft.world.level.Level __lvlRain && __lvlRain.isRaining())')
        $t = [regex]::Replace($t, '(\w+)\.getLevelData\(\)\.isThundering\(\)', '($1 instanceof net.minecraft.world.level.Level __lvlThunder && __lvlThunder.isThundering())')
        $t = $t.Replace('MelsDecoModBlocks.IRON_CHAIN_LINK_FENCE', 'MelsDecoModBlocks.CHAIN_LINK_FENCE')
        $t = $t.Replace('MelsDecoModItems.IRON_CHAIN_LINK_FENCE', 'MelsDecoModItems.CHAIN_LINK_FENCE')
        $t = $t.Replace('MelsDecoModBlocks.IRON_CHAINSAW', 'MelsDecoModBlocks.CHAINSAW')
        $t = $t.Replace('MelsDecoModItems.IRON_CHAINSAW_ITEM', 'MelsDecoModItems.CHAINSAW_ITEM')
        $t = $t.Replace('MelsDecoModItems.IRON_CHAINSAW', 'MelsDecoModItems.CHAINSAW')
        $t = [regex]::Replace($t, '\.copyTag\(\)\s*\r?\n?\s*\.getDouble\(([^)]+)\)', '.copyTag().getDoubleOr($1, Double.NaN)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\.getDouble\(([^)]+)\)', '.copyTag().getDoubleOr($1, Double.NaN)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\s*\r?\n?\s*\.getBoolean\(([^)]+)\)', '.copyTag().getBooleanOr($1, false)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\.getBoolean\(([^)]+)\)', '.copyTag().getBooleanOr($1, false)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\s*\r?\n?\s*\.getInt\(([^)]+)\)', '.copyTag().getIntOr($1, 0)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\.getInt\(([^)]+)\)', '.copyTag().getIntOr($1, 0)')
        $t = [regex]::Replace($t, '\.copyTag\(\)\s*\r?\n?\s*\.getString\(([^)]+)\)', '.copyTag().getStringOr($1, "")')
        $t = [regex]::Replace($t, '\.copyTag\(\)\.getString\(([^)]+)\)', '.copyTag().getStringOr($1, "")')
        $t = $t -replace '\.getPersistentData\(\)\.getBoolean\(([^)]+)\)', '.getPersistentData().getBooleanOr($1, false)'
        $t = $t -replace '\.getPersistentData\(\)\.getString\(([^)]+)\)', '.getPersistentData().getStringOr($1, "")'
        $t = $t -replace '\.getPersistentData\(\)\.getInt\(([^)]+)\)', '.getPersistentData().getIntOr($1, 0)'
        $t = $t -replace '\.getPersistentData\(\)\.getDouble\(([^)]+)\)', '.getPersistentData().getDoubleOr($1, 0.0)'
        if ($t -match '\.loadWithComponents\s*\(\s*\w+\s*,') {
            $t = [regex]::Replace($t,
                '\.loadWithComponents\s*\(\s*(\w+)\s*,\s*([^)]+?)\.registryAccess\(\)\s*\)',
                '.loadWithComponents(TagValueInput.create(ProblemReporter.DISCARDING, $2.registryAccess(), $1))')
            if ($t -match '\bTagValueInput\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.level\.storage\.TagValueInput\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                    "`$1`r`nimport net.minecraft.util.ProblemReporter;`r`nimport net.minecraft.world.level.storage.TagValueInput;`r`n", 1)
            }
        }
        # Item tooltip / hurtEnemy / inventoryTick (Mel cosmetics)
        if ($t -match 'void\s+appendHoverText\s*\(\s*ItemStack\s+\w+\s*,\s*TooltipContext\s+\w+\s*,\s*List<\s*Component\s*>') {
            if ($t -notmatch 'import\s+java\.util\.function\.Consumer;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', "`$1`r`nimport java.util.function.Consumer;`r`nimport net.minecraft.world.item.component.TooltipDisplay;`r`n", 1)
            }
            $t = [regex]::Replace($t,
                'void\s+appendHoverText\s*\(\s*ItemStack\s+(\w+)\s*,\s*TooltipContext\s+(\w+)\s*,\s*List<\s*Component\s*>\s+(\w+)\s*,\s*TooltipFlag\s+(\w+)\s*\)',
                'void appendHoverText(ItemStack $1, TooltipContext $2, TooltipDisplay display, Consumer<Component> $3, TooltipFlag $4)')
            $t = [regex]::Replace($t,
                'super\.appendHoverText\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)',
                'super.appendHoverText($1, $2, display, $3, $4)')
            $t = [regex]::Replace($t, '\b(\w+)\.add\((Component\.[^;]+)\)', '$1.accept($2)')
        }
        $t = [regex]::Replace($t,
            'public\s+boolean\s+hurtEnemy\s*\(\s*ItemStack\s+(\w+)\s*,\s*LivingEntity\s+(\w+)\s*,\s*LivingEntity\s+(\w+)\s*\)',
            'public void hurtEnemy(ItemStack $1, LivingEntity $2, LivingEntity $3)')
        $t = [regex]::Replace($t,
            '(public\s+void\s+hurtEnemy\s*\([^)]*\)\s*\{(?:[^{}]|\{[^{}]*\})*?)return\s+(?:true|false)\s*;',
            '$1')
        $t = $t.Replace('LivingEntity.getSlotForHand(entity.getUsedItemHand())', 'entity.getUsedItemHand().asEquipmentSlot()')
        $t = [regex]::Replace($t,
            'public\s+void\s+inventoryTick\s*\(\s*ItemStack\s+(\w+)\s*,\s*Level\s+(\w+)\s*,\s*Entity\s+(\w+)\s*,\s*int\s+(\w+)\s*,\s*boolean\s+(\w+)\s*\)',
            'public void inventoryTick(ItemStack $1, net.minecraft.server.level.ServerLevel $2, Entity $3, net.minecraft.world.entity.EquipmentSlot $4)')
        $t = [regex]::Replace($t,
            'super\.inventoryTick\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*\w+\s*\)',
            'super.inventoryTick($1, $2, $3, $4)')
        $t = $t -replace 'super\.inventoryTick\(([^,]+),\s*([^,]+),\s*([^,]+),\s*\$4\)', 'super.inventoryTick($1, $2, $3, slot)'
        $armorWorn = 'java.util.List.of($1.getItemBySlot(net.minecraft.world.entity.EquipmentSlot.HEAD), $1.getItemBySlot(net.minecraft.world.entity.EquipmentSlot.CHEST), $1.getItemBySlot(net.minecraft.world.entity.EquipmentSlot.LEGS), $1.getItemBySlot(net.minecraft.world.entity.EquipmentSlot.FEET)).contains($2)'
        $t = [regex]::Replace($t,
            'Iterables\.contains\(\s*(\w+)\.getArmorSlots\(\)\s*,\s*(\w+)\s*\)',
            $armorWorn)
        $t = [regex]::Replace($t,
            'Iterables\.contains\(\s*(\w+)\.getEquippedSlots\s*\(\s*net\.minecraft\.world\.entity\.EquipmentSlotGroup\.ARMOR\s*\)\s*,\s*(\w+)\s*\)',
            $armorWorn)
        $t = $t.Replace('.getArmorSlots()', '.getEquippedSlots(net.minecraft.world.entity.EquipmentSlotGroup.ARMOR)')
        if ($t -match 'RangeSelectItemModelProperty|implements\s+ItemModel\b|LegacyOverrideSelectItemModel') {
            $t = [regex]::Replace($t,
                '(public\s+float\s+get\s*\(\s*ItemStack\s+\w+\s*,\s*@Nullable\s+ClientLevel\s+\w+\s*,\s*@Nullable\s+)LivingEntity(\s+)(\w+)(\s*,\s*int\s+\w+\s*\))',
                '${1}ItemOwner${2}${3}${4}')
            $t = $t -replace '@Nullable LivingEntity entity', '@Nullable ItemOwner entity'
            $t = $t -replace '@Nullable LivingEntity var3', '@Nullable ItemOwner var3'
            if ($t -notmatch 'DisplaySprayPaintDesignItemProcedure\.execute\([^)]*asLivingEntity') {
                $t = [regex]::Replace($t,
                    'DisplaySprayPaintDesignItemProcedure\.execute\((\w+)\)',
                    'DisplaySprayPaintDesignItemProcedure.execute($1 != null ? $1.asLivingEntity() : null)')
            }
            $t = $t.Replace(
                'this.property.get(itemStack, level, entity, seed, displayContext)',
                'this.property.get(itemStack, level, entity == null ? null : entity.asLivingEntity(), seed, displayContext)')
            if ($t -match '\bItemOwner\b' -and $t -notmatch 'import\s+net\.minecraft\.world\.entity\.ItemOwner\s*;') {
                $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)',
                    "`$1`r`nimport net.minecraft.world.entity.ItemOwner;`r`n", 1)
            }
        }
        # Entity type tag checks
        $t = [regex]::Replace($t, '\.getType\(\)\.is\(([^)]+)\)', '.getType().builtInRegistryHolder().is($1)')

        # EntityTickEvent.Post.getEntity() is Entity, not LivingEntity
        $t = $t -replace 'LivingEntity animation = event\.getEntity\(\);', 'net.minecraft.world.entity.Entity animation = event.getEntity();'
        $t = $t -replace 'String animation = syncable\.getSyncedAnimation\(\);', 'String syncedAnim = syncable.getSyncedAnimation();'
        $t = $t -replace 'if \(!animation\.equals\("undefined"\)\)', 'if (!syncedAnim.equals("undefined"))'
        $t = $t -replace 'syncable\.animationprocedure = animation;', 'syncable.animationprocedure = syncedAnim;'

        # MobEffect 26.2 — kept here for 1.20.1 residue route; primary copy is in
        # Invoke-Minecraft262CompileRepairPass so 1.21.x Mode B also applies them.
        $nlFx = [Environment]::NewLine
        $t = $t -replace 'boolean isDurationEffectTick\(', 'boolean shouldApplyEffectTickThisTick('
        $t = [regex]::Replace($t,
            '(?m)^(\s*)(?:@Override\s*)?public void applyEffectTick\(LivingEntity (\w+), int (\w+)\) \{([^}]*)\}',
            '${1}public boolean applyEffectTick(ServerLevel level, LivingEntity $2, int $3) {$4 return true; }')
        $t = [regex]::Replace($t,
            '(?m)^(\s*)(?:@Override\s*)?public boolean applyEffectTick\(LivingEntity (\w+), int (\w+)\)',
            '${1}public boolean applyEffectTick(ServerLevel level, LivingEntity $2, int $3)')
        $t = $t -replace 'super\.applyEffectTick\(\s*(\w+)\s*,\s*(\w+)\s*\)', 'super.applyEffectTick(level, $1, $2)'
        if ($t -match 'applyEffectTick\(\s*ServerLevel\b' -and $t -notmatch 'import\s+net\.minecraft\.server\.level\.ServerLevel\s*;') {
            $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;\s*)', ("`$1${nlFx}import net.minecraft.server.level.ServerLevel;${nlFx}"), 1)
        }
        $t = [regex]::Replace($t,
            '(?ms)\s*(?:@Override\s*)?public\s+boolean\s+renderInventoryText\s*\([^)]*\)\s*\{\s*return\s+false;\s*\}',
            '')
        $bodyNoImp = [regex]::Replace($t, '(?m)^import\s+[^;]+;\s*\r?\n', '')
        if ($bodyNoImp -notmatch '\bEffectRenderingInventoryScreen\b') {
            $t = $t -replace '(?m)^import\s+net\.minecraft\.client\.gui\.screens\.inventory\.EffectRenderingInventoryScreen\s*;\r?\n', ''
        }
        if ($bodyNoImp -notmatch '\bGuiGraphicsExtractor\b') {
            $t = $t -replace '(?m)^import\s+net\.minecraft\.client\.gui\.GuiGraphicsExtractor\s*;\r?\n', ''
        }

        # CompoundTag 26.2 Optional accessors — only NBT variables, never Brigadier getDouble
        foreach ($nbtVar in @('nbt', 'tag', 'compound', 'compoundTag')) {
            $t = $t -replace "\b$nbtVar\.getBoolean\(([^)]+)\)", "$nbtVar.getBooleanOr(`$1, false)"
            $t = $t -replace "\b$nbtVar\.getDouble\(([^)]+)\)", "$nbtVar.getDoubleOr(`$1, 0.0)"
            $t = $t -replace "\b$nbtVar\.getInt\(([^)]+)\)", "$nbtVar.getIntOr(`$1, 0)"
            $t = $t -replace "\b$nbtVar\.getString\(([^)]+)\)", "$nbtVar.getStringOr(`$1, `"`")"
        }

        # MCreator SimpleChannel leftover
        $t = [regex]::Replace($t, '(?s)SimpleChannel\s+\w+\s*=\s*\w+\.PACKET_HANDLER;.*?\.send\([^;]+;', 'this.setDirty();')
        $t = [regex]::Replace($t, '(?m)^\s*\w+\.PACKET_HANDLER\.send\([^;]+;\s*$', '         /* 26.2 payload sync: RegisterPayloadHandlersEvent */')
        $t = [regex]::Replace($t,
            '(?s)public static void handler\([^)]*\) \{.*?\n      \}',
            "public static void handler(SavedDataSyncMessage message, Object contextSupplier) { /* 26.2 IPayloadContext */ }")

        if ($t -match 'extends SavedData') {
            $t = $t -replace 'void read\(CompoundTag nbt\)', 'void read(CompoundTag nbt, net.minecraft.core.HolderLookup.Provider lookup)'
            $t = $t -replace 'CompoundTag save\(CompoundTag nbt\)', 'CompoundTag save(CompoundTag nbt, net.minecraft.core.HolderLookup.Provider lookup)'
            $t = $t -replace 'data\.read\(tag\);', 'data.read(tag, null);'
            $t = $t -replace '\.read\(buffer\.readNbt\(\)\)', '.read(buffer.readNbt(), null)'
            $t = $t -replace 'message\.data\.save\(new CompoundTag\(\)\)', '((message.data instanceof WorldVariables wv) ? wv.save(new CompoundTag(), null) : ((MapVariables)message.data).save(new CompoundTag(), null))'

            $t = [regex]::Replace($t,
                '(?s)public void syncData\(LevelAccessor world\) \{.*?\n      \}',
                "public void syncData(LevelAccessor world) {`r`n         this.setDirty();`r`n      }")

            if ($t -notmatch 'SavedDataType<') {
                $nl = [Environment]::NewLine
                $t = [regex]::Replace($t,
                    'public static final String DATA_NAME = "([^"]+)_worldvars";',
                    {
                        param($m)
                        $modid = $m.Groups[1].Value
                        $n = [Environment]::NewLine
                        "public static final String DATA_NAME = `"$modid`_worldvars`";$n" +
                        "      public static final com.mojang.serialization.Codec<WorldVariables> CODEC = net.minecraft.nbt.CompoundTag.CODEC.xmap(tag -> {$n" +
                        "         WorldVariables instance = new WorldVariables();$n" +
                        "         instance.read(tag, null);$n" +
                        "         return instance;$n" +
                        "      }, instance -> instance.save(new net.minecraft.nbt.CompoundTag(), null));$n" +
                        "      public static final net.minecraft.world.level.saveddata.SavedDataType<WorldVariables> TYPE = new net.minecraft.world.level.saveddata.SavedDataType<>($n" +
                        "         net.minecraft.resources.Identifier.fromNamespaceAndPath(`"$modid`", `"worldvars`"),$n" +
                        "         WorldVariables::new,$n" +
                        "         CODEC$n" +
                        "      );"
                    })
                $t = [regex]::Replace($t,
                    'public static final String DATA_NAME = "([^"]+)_mapvars";',
                    {
                        param($m)
                        $modid = $m.Groups[1].Value
                        $n = [Environment]::NewLine
                        "public static final String DATA_NAME = `"$modid`_mapvars`";$n" +
                        "      public static final com.mojang.serialization.Codec<MapVariables> CODEC = net.minecraft.nbt.CompoundTag.CODEC.xmap(tag -> {$n" +
                        "         MapVariables instance = new MapVariables();$n" +
                        "         instance.read(tag, null);$n" +
                        "         return instance;$n" +
                        "      }, instance -> instance.save(new net.minecraft.nbt.CompoundTag(), null));$n" +
                        "      public static final net.minecraft.world.level.saveddata.SavedDataType<MapVariables> TYPE = new net.minecraft.world.level.saveddata.SavedDataType<>($n" +
                        "         net.minecraft.resources.Identifier.fromNamespaceAndPath(`"$modid`", `"mapvars`"),$n" +
                        "         MapVariables::new,$n" +
                        "         CODEC$n" +
                        "      );"
                    })
            }

            $t = [regex]::Replace($t,
                'getDataStorage\(\)\.(?:register|computeIfAbsent)\(\(e\) -> load\(e\),\s*WorldVariables::new,\s*"[^"]+"\)',
                'getDataStorage().computeIfAbsent(TYPE)')
            $t = [regex]::Replace($t,
                'getDataStorage\(\)\.(?:register|computeIfAbsent)\(\(e\) -> load\(e\),\s*MapVariables::new,\s*"[^"]+"\)',
                'getDataStorage().computeIfAbsent(TYPE)')
        }

        # BlockPos.containing already mapped; leftover parse(x,y,z)
        $t = $t -replace 'BlockPos\.parse\(', 'BlockPos.containing('
        $t = $t -replace 'Mth\.add\(RandomSource\.create\(\)', 'Mth.nextInt(RandomSource.create()'
        $t = $t -replace 'Mth\.add\(RandomSource\.add\(\)', 'Mth.nextInt(RandomSource.create()'
        $t = $t -replace '\.hasProperty\(\)', '.canOcclude()'
        $t = [regex]::Replace($t,
            '(SpawnGroupData retval = super\.finalizeSpawn\(world, difficulty, reason, livingdata\);\s*)(\s*)((?:[\w.]+)?OnInitialEntitySpawnProcedure\.execute\([^;]+;)',
            '$1$2if (reason != net.minecraft.world.entity.EntitySpawnReason.SPAWN_ITEM_USE && reason != net.minecraft.world.entity.EntitySpawnReason.COMMAND && reason != net.minecraft.world.entity.EntitySpawnReason.DISPENSER && reason != net.minecraft.world.entity.EntitySpawnReason.MOB_SUMMONED) { $3 }')
        $t = $t -replace 'super\.m_5993_\(', 'super.awardKillScore('
        $t = $t -replace '\.getLookAngle\(([^,]+),\s*(?:true|false)\)', '.sendSystemMessage($1)'
        $t = $t -replace 'void awardKillScore\(Entity (\w+), int \w+, DamageSource (\w+)\)', 'void awardKillScore(Entity $1, DamageSource $2)'
        $t = $t -replace 'super\.awardKillScore\((\w+),\s*\w+,\s*(\w+)\)', 'super.awardKillScore($1, $2)'
        $t = $t -replace '(?<![\w.])event\.player\b', 'event.getEntity()'
        # Do not rewrite package net.neoforged.neoforge.event.level
        $t = $t -replace '(?<![\w.])event\.level\b(?!\s*\()(?!\.)', 'event.getLevel()'
        $t = $t -replace 'net\.neoforged\.neoforge\.event\.getLevel\(\)\.BlockEvent', 'net.neoforged.neoforge.event.level.BlockEvent'
        $t = $t -replace 'net\.neoforged\.neoforge\.event\.getLevel\(\)\.block', 'net.neoforged.neoforge.event.level.block'
        $t = $t -replace '(?m)^\s*\w+\.addNetworkMessage\([^;]+;\s*$', '      /* 26.2: RegisterPayloadHandlersEvent */'
        $t = $t -replace '\)\.immutable\(\)', ')'
        $t = $t -replace '\)\.withSuppressedOutput\(\)', ')'
        $t = $t -replace 'MobEffects\.MOVEMENT_SLOWDOWN', 'MobEffects.SLOWNESS'
        $t = $t -replace 'MobEffects\.MOVEMENT_SPEED', 'MobEffects.SPEED'
        $t = $t -replace 'MobEffects\.DAMAGE_RESISTANCE', 'MobEffects.RESISTANCE'
        $t = $t -replace '(\w+)\.hurt\(new DamageSource\(world\.registryAccess\(\)\.get\(Registries\.DAMAGE_TYPE\)\.holder\(DamageTypes\.GENERIC\)\)', '$1.hurt($1.damageSources().generic()'
        $t = $t -replace 'connection\.teleport\(([^;]+),\s*(\w+)\.getYRot\(\),\s*\2\)', 'connection.teleport($1, $2.getYRot(), $2.getXRot())'
        $t = $t -replace 'world\.isEmptyBlock\(([^,]+),\s*false\)', 'world.destroyBlock($1, false)'
        $t = $t -replace '\.getCooldowns\(\)\.register\(', '.getCooldowns().addCooldown('
        $t = $t -replace '\.getCooldowns\(\)\.addCooldown\(Items\.(\w+),\s*(\d+)\)', '.getCooldowns().addCooldown(new net.minecraft.world.item.ItemStack(Items.$1), $2)'
        $t = $t -replace 'this\.dropExperience\(\);', 'if (this.level() instanceof net.minecraft.server.level.ServerLevel _xpLevel) { this.dropExperience(_xpLevel, this); }'
        $t = $t -replace 'protected void dropCustomDeathLoot\(DamageSource (\w+), int \w+, boolean (\w+)\)', 'protected void dropCustomDeathLoot(net.minecraft.server.level.ServerLevel level, DamageSource $1, boolean $2)'
        $t = $t -replace 'super\.dropCustomDeathLoot\((\w+),\s*\w+,\s*(\w+)\);', 'super.dropCustomDeathLoot(level, $1, $2);'
        $t = $t -replace '\(MobEffect\)(\w+\.\w+)\.get\(\)', '$1'
        $t = $t -replace 'MobEffects\.DIG_SLOWDOWN', 'MobEffects.MINING_FATIGUE'
        $t = $t -replace '(\w+)\.hurt\(new DamageSource\(world\.registryAccess\(\)\.(?:get|registryOrThrow)\(Registries\.DAMAGE_TYPE\)\.(?:holder|getHolderOrThrow)\(DamageTypes\.GENERIC\)\)', '$1.hurt($1.damageSources().generic()'
        $t = $t -replace 'UnmodifiableIterator (\w+) = _bso\.getValues\(\)\.entrySet\(\)\.iterator\(\);', 'java.util.Iterator $1 = _bso.getValues().map(v -> java.util.Map.entry((Property<?>)v.property(), (Comparable<?>)v.value())).iterator();'

        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $touched++
        }
    }
    return $touched
}

function Invoke-ModConfigSpecOrderPass {
    <#
    .SYNOPSIS
      Fix decompiled MCreator ModConfigSpec classes that call BUILDER.build() before .define().
      That order throws "Cannot get config value before spec is built" on world join / player spawn
      (proven disconnect on The Knocker).
    #>
    param([string]$Root)

    $files = Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue
    $touched = 0
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        if ($t -notmatch 'ModConfigSpec' -or $t -notmatch 'BUILDER\.build\(\)' -or $t -notmatch '\.define\(') { continue }

        $buildIdx = $t.IndexOf('BUILDER.build()')
        $defineIdx = $t.IndexOf('.define(')
        if ($buildIdx -lt 0 -or $defineIdx -lt 0 -or $defineIdx -le $buildIdx) { continue }

        $o = $t
        # Drop early SPEC = BUILDER.build() field assignment (common MCreator decompile order)
        $t = [regex]::Replace($t,
            '(?m)^\s*public\s+static\s+final\s+ModConfigSpec\s+SPEC\s*=\s*BUILDER\.build\(\)\s*;\s*\r?\n',
            '')

        # If SPEC field vanished entirely, redeclare at end before last class brace
        if ($t -notmatch 'ModConfigSpec\s+SPEC\b') {
            $t = [regex]::Replace($t, '(?s)(.*\r?\n)(\})\s*\z',
                "`$1    public static final ModConfigSpec SPEC = BUILDER.build();`r`n`$2`r`n", 1)
        }
        elseif ($t -match 'public\s+static\s+final\s+ModConfigSpec\s+SPEC\s*;' -and $t -notmatch 'SPEC\s*=\s*BUILDER\.build\(\)') {
            $t = [regex]::Replace($t, '(?s)(.*\r?\n)(\})\s*\z',
                "`$1    static { SPEC = BUILDER.build(); }`r`n`$2`r`n", 1)
        }
        elseif ($t -notmatch 'SPEC\s*=\s*BUILDER\.build\(\)') {
            # SPEC field still missing assignment after strip
            $t = [regex]::Replace($t, '(?s)(.*\r?\n)(\})\s*\z',
                "`$1    public static final ModConfigSpec SPEC = BUILDER.build();`r`n`$2`r`n", 1)
        }

        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $touched++
            Write-Info "ModConfigSpec order fixed: $($f.Name)"
        }
    }
    return $touched
}

function Invoke-RegistryTemplatePass {
    <#
    .SYNOPSIS
      Rewrite simple DeferredRegister entity/sound patterns to NeoForge 26 createEntities / Registries forms.
    #>
    param([string]$Root)

    $fixed = 0
    $files = Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        $o = $t

        # DeferredRegister.create(ForgeRegistries/BuiltInRegistries.ENTITY_TYPE[S], modid)
        $t = [regex]::Replace($t,
            'DeferredRegister\.create\(\s*(?:ForgeRegistries\.ENTITY_TYPES|BuiltInRegistries\s*/\*[^*]*\*/\s*\.ENTITY_TYPE|BuiltInRegistries\.ENTITY_TYPE)\s*,\s*([^)]+)\)',
            'DeferredRegister.createEntities($1)')
        $t = [regex]::Replace($t,
            'DeferredRegister\.create\(\s*(?:ForgeRegistries\.SOUND_EVENTS|BuiltInRegistries\s*/\*[^*]*\*/\s*\.SOUND_EVENT|BuiltInRegistries\.SOUND_EVENT)\s*,\s*([^)]+)\)',
            'DeferredRegister.create(net.minecraft.core.registries.Registries.SOUND_EVENT, $1)')
        $t = [regex]::Replace($t,
            'DeferredRegister\.create\(\s*(?:ForgeRegistries\.ITEMS|BuiltInRegistries\.ITEM)\s*,\s*([^)]+)\)',
            'DeferredRegister.createItems($1)')
        $t = [regex]::Replace($t,
            'DeferredRegister\.create\(\s*(?:ForgeRegistries\.BLOCKS|BuiltInRegistries\.BLOCK)\s*,\s*([^)]+)\)',
            'DeferredRegister.createBlocks($1)')
        $t = [regex]::Replace($t,
            'DeferredRegister\.create\(\s*(?:ForgeRegistries\.FEATURES|BuiltInRegistries\.FEATURE)\s*,\s*([^)]+)\)',
            'DeferredRegister.create(net.minecraft.core.registries.Registries.FEATURE, $1)')
        $t = [regex]::Replace($t,
            'DeferredRegister\.create\(\s*(?:ForgeRegistries\.MOB_EFFECTS|BuiltInRegistries\.MOB_EFFECT)\s*,\s*([^)]+)\)',
            'DeferredRegister.create(net.minecraft.core.registries.Registries.MOB_EFFECT, $1)')

        $modidMatch = [regex]::Match($t, 'DeferredRegister\.createEntities\("([^"]+)"\)')
        if ($modidMatch.Success) {
            $mid = $modidMatch.Groups[1].Value
            $t = $t -replace 'entityTypeBuilder\.build\((\w+)\)',
                "entityTypeBuilder.build(net.minecraft.resources.ResourceKey.create(net.minecraft.core.registries.Registries.ENTITY_TYPE, net.minecraft.resources.Identifier.fromNamespaceAndPath(`"$mid`", `$1)))"
        }

        # Ensure imports for DeferredHolder when used
        if ($t -match 'DeferredHolder' -and $t -notmatch 'import net\.neoforged\.neoforge\.registries\.DeferredHolder') {
            $t = $t -replace '(package [^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.registries.DeferredHolder;"
        }
        if ($t -match 'DeferredRegister\.createEntities' -and $t -notmatch 'import net\.neoforged\.neoforge\.registries\.DeferredRegister') {
            $t = $t -replace '(package [^;]+;\s*)', "`$1`r`nimport net.neoforged.neoforge.registries.DeferredRegister;"
        }

        $t = $t -replace 'DeferredHolder<\s*EntityType<([^>]+)>\s*>', 'DeferredHolder<EntityType<?>, EntityType<$1>>'
        $t = $t -replace 'private static <T extends Entity> DeferredHolder<EntityType<T>>', 'private static <T extends Entity> DeferredHolder<EntityType<?>, EntityType<T>>'
        $t = $t -replace 'DeferredHolder<Block>(?!\s*,)', 'DeferredHolder<Block, Block>'
        $t = $t -replace 'DeferredHolder<Item>(?!\s*,)', 'DeferredHolder<Item, Item>'
        $t = $t -replace 'DeferredHolder<Feature<\?>>(?!\s*,)', 'DeferredHolder<Feature<?>, Feature<?>>'
        $t = $t -replace 'DeferredHolder<SoundEvent>(?!\s*,)', 'DeferredHolder<SoundEvent, SoundEvent>'
        $t = $t -replace 'DeferredHolder<MobEffect>(?!\s*,)', 'DeferredHolder<MobEffect, MobEffect>'
        $t = $t -replace 'DeferredHolder<CreativeModeTab>(?!\s*,)', 'DeferredHolder<CreativeModeTab, CreativeModeTab>'

        # EntityType register lambda with Builder.of(...).build() - try registerEntityType when simple
        # public static final DeferredHolder<EntityType<X>, ...> NAME = REG.register("id", () -> EntityType.Builder.of(X::new, CAT)...build());
        # Too risky to auto-convert all forms; leave for compile errors.

        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $fixed++
        }
    }
    return $fixed
}

function Invoke-BlockItemIdPass {
    <#
    .SYNOPSIS
      Minecraft 26.2 requires Block/Item Properties.setId before construction.
      DeferredRegister.Blocks.registerBlock / Items.registerItem inject the id.
      MCreator no-arg ctors that call Properties.of() / new Item.Properties() NPE:
      "Block id not set" / "Item id not set" (TOWW crash 2026-08-23; gecko_kings 2026-09-04).
    #>
    param([string]$Root)

    $files = @(Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue)
    $touched = 0

    # Pass 1: rewrite no-arg ctors so type files are on disk before registry method-ref conversion.
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        $o = $t

        # Block: public Foo() { super( [extra args,] Properties.of()... } including multiline / Door / Stairs / Flower / LiquidBlock
        $t = [regex]::Replace($t,
            '(?s)public (\w+)\(\) \{(\s*super\((?:[\s\S]*?))Properties\.of\(\)',
            'public $1(net.minecraft.world.level.block.state.BlockBehaviour.Properties properties) {$2properties')
        $t = [regex]::Replace($t,
            'public (\w+)\(\) \{\s*super\(\(new BlockBehaviour\.Properties\(\)\)',
            'public $1(net.minecraft.world.level.block.state.BlockBehaviour.Properties properties) { super(properties')

        # Item: public Foo() { super( [extra args,] new Properties()... } including armor inner + BucketItem
        # Skip rewrite when a Properties ctor already exists — otherwise duplicate erasure
        # (BlankMobCaptureCardItem / CreativeBlankMobCaptureCardItem on Easy Mob Farm).
        $itemCtorMatches = @([regex]::Matches($t, '(?s)public (\w+)\(\) \{(\s*super\((?:[\s\S]*?))new (?:Item\.)?Properties\(\)'))
        for ($mi = $itemCtorMatches.Count - 1; $mi -ge 0; $mi--) {
            $m = $itemCtorMatches[$mi]
            $cls = $m.Groups[1].Value
            $hasPropsCtor = $t -match ("public\s+" + [regex]::Escape($cls) + "\s*\(\s*(?:net\.minecraft\.world\.item\.Item\.)?Properties\s+\w+\s*\)")
            if ($hasPropsCtor) { continue }
            $replacement = "public $cls(net.minecraft.world.item.Item.Properties properties) {$($m.Groups[2].Value)properties"
            $t = $t.Remove($m.Index, $m.Length).Insert($m.Index, $replacement)
        }
        # Collapse FQN + short Properties ctor duplicates (same erasure).
        $t = [regex]::Replace($t,
            '(?s)(public\s+(\w+)\s*\(\s*net\.minecraft\.world\.item\.Item\.Properties\s+\w+\s*\)\s*\{(?:[^{}]|\{[^{}]*\})*\})\s*public\s+\2\s*\(\s*Properties\s+\w+\s*\)\s*\{(?:[^{}]|\{[^{}]*\})*\}',
            '$1')
        $t = [regex]::Replace($t,
            '(?s)(public\s+(\w+)\s*\(\s*Properties\s+\w+\s*\)\s*\{(?:[^{}]|\{[^{}]*\})*\})\s*public\s+\2\s*\(\s*net\.minecraft\.world\.item\.Item\.Properties\s+\w+\s*\)\s*\{(?:[^{}]|\{[^{}]*\})*\}',
            '$1')

        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $touched++
        }
    }

    # Pass 2: registry helpers (reads rewritten ctors from disk)
    $blockRoot = Join-Path $Root 'src\main\java'
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        $o = $t

        $t = $t -replace 'public static final DeferredRegister<Block> REGISTRY', 'public static final DeferredRegister.Blocks REGISTRY'
        $t = $t -replace 'public static final DeferredRegister<Item> REGISTRY', 'public static final DeferredRegister.Items REGISTRY'

        $t = [regex]::Replace($t,
            'REGISTRY\.register\("([^"]+)",\s*\(\)\s*->\s*new (\w+Block)\(\)\)',
            'REGISTRY.registerBlock("$1", $2::new)')
        $t = [regex]::Replace($t,
            'REGISTRY\.register\("([^"]+)",\s*\(\)\s*->\s*new (\w+Item)\(\)\)',
            'REGISTRY.registerItem("$1", $2::new)')

        if ($t -match 'REGISTRY\.register\(\s*"[^"]+"\s*,\s*[\w.]+::new') {
            $t = [regex]::Replace($t, 'REGISTRY\.register\(\s*"([^"]+)"\s*,\s*([\w.]+)::new\s*\)', {
                param($m)
                $id = $m.Groups[1].Value
                $typeName = $m.Groups[2].Value
                $simple = ($typeName -split '\.')[-1]
                $outer = ($typeName -split '\.')[0]
                $typeFile = Get-ChildItem -LiteralPath $blockRoot -Recurse -Filter ($outer + '.java') -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($null -ne $typeFile) {
                    $typeText = [System.IO.File]::ReadAllText($typeFile.FullName)
                    $hasPropsCtor = $typeText -match ('public\s+' + [regex]::Escape($simple) + '\s*\(\s*(?:[\w.]+)?Properties\s+\w+\s*\)')
                    $hasNoArgCtor = $typeText -match ('public\s+' + [regex]::Escape($simple) + '\s*\(\s*\)')
                    if ($hasPropsCtor -and -not $hasNoArgCtor) {
                        if ($typeName -match 'Block$') {
                            return ('REGISTRY.registerBlock("' + $id + '", ' + $typeName + '::new)')
                        }
                        return ('REGISTRY.registerItem("' + $id + '", ' + $typeName + '::new)')
                    }
                }
                return $m.Value
            })
        }

        $t = [regex]::Replace($t,
            'REGISTRY\.register(?:Item)?\("([^"]+)",\s*\(\)\s*->\s*new SpawnEggItem\(new Item\.Properties\(\)\.spawnEgg\(([^)]+)\)\)\)',
            'REGISTRY.registerItem("$1", properties -> new SpawnEggItem(properties.spawnEgg($2)))')
        $t = [regex]::Replace($t,
            'REGISTRY\.register(?:Item)?\("([^"]+_spawn_egg)",\s*\(\)\s*->\s*new SpawnEggItem\(new Item\.Properties\(\)\)\)',
            'REGISTRY.registerItem("$1", properties -> new SpawnEggItem(properties))')

        # MCreator 26.1.2 BlockItem helpers: registerItem injects setId into prop
        $t = $t -replace 'REGISTRY\.register\(block\.getId\(\)\.getPath\(\),\s*\(\)\s*->\s*new BlockItem\(\(Block\)block\.get\(\),\s*(?:new Item\.Properties\(\)|properties)\)\)',
            'REGISTRY.registerItem(block.getId().getPath(), prop -> new BlockItem((Block)block.get(), prop), () -> properties)'
        $t = $t -replace 'REGISTRY\.register\(block\.getId\(\)\.getPath\(\),\s*\(\)\s*->\s*new DoubleHighBlockItem\(\(Block\)block\.get\(\),\s*(?:new Item\.Properties\(\)|properties)\)\)',
            'REGISTRY.registerItem(block.getId().getPath(), prop -> new DoubleHighBlockItem((Block)block.get(), prop), () -> properties)'

        if (Get-Command Convert-CustomBlockRegistrationText -ErrorAction SilentlyContinue) {
            $t = Convert-CustomBlockRegistrationText -Text $t
        }

        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $touched++
        }
    }
    return $touched
}

function Invoke-GeckoLib26Pass {
    <#
    .SYNOPSIS
      GeckoLib 5.5 / NeoForge 26.2 (The One Who Watches + Friend proven):
      - GeoModel IDs are bare names (already stripped of geo/ and .json)
      - getTextureResource(GeoRenderState) cannot call entity.getTexture(); use the
        entity's synched TEXTURE default (never unknown.png)
      - ControllerRegistrar.add takes AnimationController, not AnimationController[]
    #>
    param([string]$Root)

    $javaRoot = Join-Path $Root 'src\main\java'
    $textureDefault = @{}
    foreach ($ef in Get-ChildItem $javaRoot -Recurse -Filter '*Entity.java' -File -ErrorAction SilentlyContinue) {
        $et = [System.IO.File]::ReadAllText($ef.FullName)
        $m = [regex]::Match($et, 'define\(\s*TEXTURE\s*,\s*"([^"]+)"\s*\)')
        if ($m.Success) {
            $textureDefault[$ef.BaseName] = $m.Groups[1].Value
        }
    }

    $touched = 0
    foreach ($f in Get-ChildItem $javaRoot -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        $o = $t

        if ($t -match 'extends\s+GeoModel') {
            $tex = 'toww_reborn'
            $ent = [regex]::Match($t, 'extends\s+GeoModel<(\w+)>')
            if ($ent.Success -and $textureDefault.ContainsKey($ent.Groups[1].Value)) {
                $tex = $textureDefault[$ent.Groups[1].Value]
            }
            $t = $t -replace 'textures/entities/unknown\.png', "textures/entities/$tex.png"
        }

        $t = $t -replace 'data\.add\(new AnimationController\[\]\{new AnimationController(?:<>)?\(', 'data.add(new AnimationController<>('
        $t = $t -replace 'controllers\.add\(new AnimationController\[\]\{new AnimationController(?:<>)?\(', 'controllers.add(new AnimationController<>('
        $t = $t -replace '(this::\w+)\)\}\);', '$1));'
        # Completed TOWW 26.2: unused procedure controller must STOP, not CONTINUE (in-place mesh jitter).
        # Do not flatten movement clips to pose1 — hunting uses chase, hanging hang, crawling pose6.
        $t = [regex]::Replace($t,
            '(?s)private PlayState procedurePredicate\(AnimationTest event\) \{.*?\n   \}',
            @'
private PlayState procedurePredicate(AnimationTest event) {
      String synced = this.getSyncedAnimation();
      if (synced != null && !synced.isEmpty() && !synced.equals("undefined")) {
         this.animationprocedure = synced;
      }
      String clip = this.animationprocedure;
      if (clip == null || clip.isEmpty() || clip.equals("empty") || clip.equals("undefined")) {
         return PlayState.STOP;
      }
      return event.setAndContinue(RawAnimation.begin().thenPlay(clip));
   }
'@)
        $t = $t -replace '(?m)^\s*this\.refreshDimensions\(\);\s*\r?\n', ''
        $t = $t -replace 'LookAtPlayerGoal\(this, Player\.class, 1000\.0F\)', 'LookAtPlayerGoal(this, Player.class, 64.0F)'
        if ($t -match 'extends\s+Animal') {
            $t = $t -replace 'Mob\.createMobAttributes\(\)', 'Animal.createAnimalAttributes()'
        }

        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $touched++
        }
    }
    return $touched
}

function Invoke-ModEntryTemplatePass {
    param([string]$Root)

    $files = Get-ChildItem (Join-Path $Root 'src\main\java') -Recurse -Filter '*.java' -File |
        Where-Object { (Get-Content $_.FullName -Raw) -match '@Mod\(' }
    $n = 0
    foreach ($f in $files) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        $o = $t
        # Convert no-arg mod constructor using FMLJavaModLoadingContext to IEventBus + ModContainer
        if ($t -match 'FMLJavaModLoadingContext' -or $t -match 'ModLoadingContext\.get\(\)\.registerConfig') {
            if ($t -notmatch 'import net\.neoforged\.bus\.api\.IEventBus') {
                $t = $t -replace '(package [^;]+;\s*)', "`$1`r`nimport net.neoforged.bus.api.IEventBus;"
            }
            if ($t -notmatch 'import net\.neoforged\.fml\.ModContainer') {
                $t = $t -replace '(package [^;]+;\s*)', "`$1`r`nimport net.neoforged.fml.ModContainer;"
            }
            # Replace constructor signature public Foo() { ... getModEventBus ...}
            $t = [regex]::Replace($t,
                'public\s+(\w+)\s*\(\s*\)\s*\{',
                'public $1(IEventBus modBus, ModContainer container) {')
            $t = $t -replace '/\*\s*TODO:\s*inject IEventBus\s*\*/\s*', ''
            $t = $t -replace '/\*\s*TODO inject IEventBus\s*\*/\s*', ''
            $t = $t -replace 'FMLJavaModLoadingContext\.get\(\)\.getModEventBus\(\)', 'modBus'
            $t = $t -replace 'var\s+modBus\s*=\s*modBus\s*;', ''
            $t = $t -replace 'ModLoadingContext\.get\(\)\.registerConfig\(', 'container.registerConfig('
            # drop unused imports
            $t = $t -replace 'import\s+net\.neoforged\.fml\.javafmlmod\.FMLJavaModLoadingContext;\r?\n', ''
            $t = $t -replace 'import\s+net\.neoforged\.fml\.ModLoadingContext;\r?\n', ''
        }
        if ($t -ne $o) {
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $n++
        }
    }
    return $n
}

function Invoke-EventBusSubscriberPass {
    <#
    .SYNOPSIS
      NeoForge 26.x no longer exposes @Mod.EventBusSubscriber the same way.
      Convert annotated static @SubscribeEvent handlers into explicit
      modBus / NeoForge.EVENT_BUS addListener registrations.
    #>
    param([string]$Root, [hashtable]$Meta)

    $javaRoot = Join-Path $Root 'src\main\java'
    if (-not (Test-Path $javaRoot)) { return 0 }

    $modBusMethods = New-Object System.Collections.Generic.List[string]
    $gameBusMethods = New-Object System.Collections.Generic.List[string]
    $imports = New-Object System.Collections.Generic.HashSet[string]
    $filesTouched = 0

    $modBusEventHints = @(
        'EntityAttributeCreationEvent', 'EntityRenderersEvent', 'RegisterParticleProvidersEvent',
        'RegisterMenuScreensEvent', 'RegisterClientReloadListenersEvent', 'BuildCreativeModeTabContentsEvent',
        'RegisterCommandsEvent'  # sometimes mod bus in older; usually game - keep game for commands below
    )

    foreach ($f in Get-ChildItem $javaRoot -Recurse -Filter '*.java') {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        # Forge 1.20.1 uses @Mod.EventBusSubscriber. NeoForge 1.21.x @EventBusSubscriber still works on 26.2
        # (proven on The Knocker). Only rewrite the Forge-style annotation; do not emit broken
        # OuterClass::method refs for nested @EventBusSubscriber config/client classes.
        if ($t -notmatch '@Mod\.EventBusSubscriber') { continue }

        $pkg = if ($t -match 'package\s+([\w\.]+)\s*;') { $Matches[1] } else { continue }
        $cls = if ($t -match 'public\s+(?:final\s+)?class\s+(\w+)') { $Matches[1] } else { continue }
        $fqcn = "$pkg.$cls"

        # Collect static subscribe methods: public static void name(EventType event)
        $methodMatches = [regex]::Matches($t, '(?s)@SubscribeEvent\s+public\s+static\s+void\s+(\w+)\s*\(\s*([\w\.]+)\s+\w+\s*\)')
        $isClientOnly = $t -match 'value\s*=\s*Dist\.CLIENT' -or $t -match 'Dist\.CLIENT'
        $busIsMod = $t -match 'Bus\.MOD'

        foreach ($mm in $methodMatches) {
            $method = $mm.Groups[1].Value
            $eventType = $mm.Groups[2].Value
            $ref = "${cls}::${method}"
            $imports.Add("import ${fqcn};") | Out-Null

            $useModBus = $busIsMod -or ($modBusEventHints | Where-Object { $eventType -match $_ })
            # Commands / ticks / living / viewport -> game bus
            if ($eventType -match 'TickEvent|ClientTick|ServerTick|Viewport|Living|Player|Level|Block|Command') {
                $useModBus = $false
            }
            if ($eventType -match 'EntityAttribute|EntityRenderers|RegisterParticle|CreativeModeTab|RegisterMenu') {
                $useModBus = $true
            }

            if ($useModBus) {
                $modBusMethods.Add("        modBus.addListener($ref);") | Out-Null
            }
            else {
                $gameBusMethods.Add("        NeoForge.EVENT_BUS.addListener($ref);") | Out-Null
            }
        }

        # Strip class-level EventBusSubscriber annotation (keep methods + SubscribeEvent for clarity optional)
        $t2 = [regex]::Replace($t, '@Mod\.EventBusSubscriber\s*\([^)]*\)\s*', "/* was EventBusSubscriber - registered via LegacyEventBootstrap */`r`n")
        $t2 = $t2 -replace '@OnlyIn\s*\(\s*Dist\.CLIENT\s*\)', '/* @OnlyIn(Dist.CLIENT) removed */'
        $t2 = $t2 -replace 'import\s+net\.neoforged\.neoforge\.api\.distmarker\.OnlyIn;\r?\n', ''
        $t2 = $t2 -replace 'import\s+net\.minecraftforge\.api\.distmarker\.OnlyIn;\r?\n', ''

        if ($t2 -ne $t) {
            [System.IO.File]::WriteAllText($f.FullName, $t2)
            $filesTouched++
        }
    }

    if ($modBusMethods.Count -eq 0 -and $gameBusMethods.Count -eq 0) {
        return $filesTouched
    }

    # Write bootstrap under primary package
    $pkg = $Meta.mod_group
    if (-not $pkg) { $pkg = 'com.example' }
    $dir = Join-Path $javaRoot ($pkg -replace '\.', [IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $importBlock = ($imports | Sort-Object) -join "`r`n"
    $modLines = if ($modBusMethods.Count) { ($modBusMethods | Select-Object -Unique) -join "`r`n" } else { '        // (none detected)' }
    $gameLines = if ($gameBusMethods.Count) { ($gameBusMethods | Select-Object -Unique) -join "`r`n" } else { '        // (none detected)' }

    $bootstrap = @"
package $pkg;

import net.neoforged.bus.api.IEventBus;
import net.neoforged.neoforge.common.NeoForge;
$importBlock

/**
 * Auto-generated by Convert-Forge1201-ToNeoForge262.
 * Replaces 1.20.1 @Mod.EventBusSubscriber automatic discovery.
 */
public final class LegacyEventBootstrap {
    public static void register(IEventBus modBus) {
$modLines
$gameLines
    }

    private LegacyEventBootstrap() {}
}
"@
    [System.IO.File]::WriteAllText((Join-Path $dir 'LegacyEventBootstrap.java'), $bootstrap.Trim() + "`r`n")

    # Wire into @Mod constructor if present
    foreach ($f in Get-ChildItem $javaRoot -Recurse -Filter '*.java') {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        if ($t -notmatch '@Mod\(') { continue }
        if ($t -match 'LegacyEventBootstrap') { break }
        if ($t -match 'public\s+\w+\s*\(\s*IEventBus\s+(\w+)') {
            $busParam = $Matches[1]
            $t = $t -replace '(package [^;]+;\s*)', "`$1`r`nimport $pkg.LegacyEventBootstrap;`r`n"
            # insert call after opening brace of constructor
            $t = [regex]::Replace($t,
                "(public\s+\w+\s*\(\s*IEventBus\s+$busParam\s*,\s*ModContainer\s+\w+\s*\)\s*\{)",
                "`$1`r`n        LegacyEventBootstrap.register($busParam);")
            [System.IO.File]::WriteAllText($f.FullName, $t)
            $filesTouched++
        }
        break
    }

    return $filesTouched
}

function Invoke-SubmitCustomGeometryPass {
    <#
    .SYNOPSIS
      Detect world-draw MultiBufferSource / bufferSource / ShapeRenderer leftovers and scaffold a
      client SubmitCustomGeometryEvent + submitShapeOutline hook (NeoForge 26.2).

      Entity-layer MultiBufferSource->SubmitNodeCollector renames stay in the API pass.
      World geometry cannot be naively renamed; this pass documents hits and drops a working stub.
    #>
    param([string]$Root, [hashtable]$Meta)

    $javaRoot = Join-Path $Root 'src\main\java'
    if (-not (Test-Path $javaRoot)) {
        return @{ touched = 0; hits = @(); scaffold = $false }
    }

    $hitFiles = New-Object System.Collections.Generic.List[string]
    $touched = 0
    $worldPattern = '\.bufferSource\s*\(|TODO 26\.2 SubmitCustomGeometryEvent|\bRenderLevelStageEvent\b|\bShapeRenderer\b|LevelRenderer\.renderLineBox|MultiBufferSource\.BufferSource|TODO 26\.2: SubmitCustomGeometryEvent'

    foreach ($f in Get-ChildItem $javaRoot -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        if ($t -notmatch $worldPattern) { continue }
        # Skip entity-only submit layers that merely mention SubmitNodeCollector after rename
        if ($t -match 'extends\s+RenderLayer\b|RenderLayer\s*<' -and $t -notmatch '\.bufferSource\s*\(|\bShapeRenderer\b|LevelRenderer\.renderLineBox|RenderLevelStageEvent|MultiBufferSource\.BufferSource') {
            continue
        }
        $rel = $f.FullName.Substring($javaRoot.Length).TrimStart('\', '/')
        $hitFiles.Add($rel.Replace('\', '/')) | Out-Null
        $touched++
    }

    $scaffold = $false
    if ($hitFiles.Count -gt 0) {
        $pkg = $Meta.mod_group
        if (-not $pkg) { $pkg = 'com.example' }
        $modId = $Meta.mod_id
        if (-not $modId) { $modId = 'examplemod' }
        $dir = Join-Path $javaRoot ($pkg -replace '\.', [IO.Path]::DirectorySeparatorChar)
        $clientDir = Join-Path $dir 'client'
        New-Item -ItemType Directory -Path $clientDir -Force | Out-Null
        $outFile = Join-Path $clientDir 'LegacySubmitCustomGeometryHooks.java'
        if (-not (Test-Path -LiteralPath $outFile)) {
            $scaffoldBody = @"
package $pkg.client;

import com.mojang.blaze3d.vertex.PoseStack;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.rendertype.RenderTypes;
import net.minecraft.world.phys.shapes.Shapes;
import net.minecraft.world.phys.shapes.VoxelShape;
import net.neoforged.api.distmarker.Dist;
import net.neoforged.bus.api.SubscribeEvent;
import net.neoforged.fml.common.EventBusSubscriber;
import net.neoforged.neoforge.client.event.SubmitCustomGeometryEvent;

/**
 * Auto-generated by Convert-Forge1201-ToNeoForge262 (v1.5.1+).
 *
 * World-space immediate buffers (MultiBufferSource / RenderBuffers.bufferSource /
 * ShapeRenderer / LevelRenderer.renderLineBox) are gone in Minecraft 26.2.
 * Submit custom outlines/geometry here via SubmitNodeCollector#submitShapeOutline.
 *
 * Evidence: NeoForge SubmitCustomGeometryEvent + BlockEntityRenderBoundsDebugRenderer.
 * Move extraction of per-frame state into ExtractLevelRenderStateEvent when needed.
 */
@EventBusSubscriber(value = Dist.CLIENT, modid = "$modId")
public final class LegacySubmitCustomGeometryHooks {
    private LegacySubmitCustomGeometryHooks() {}

    @SubscribeEvent
    public static void onSubmitCustomGeometry(SubmitCustomGeometryEvent event) {
        // Example outline at the camera-relative origin of each non-empty section.
        // Replace with your former bufferSource / ShapeRenderer drawing.
        PoseStack poseStack = event.getPoseStack();
        var camera = event.getLevelRenderState().cameraRenderState.pos;
        float lineWidth = Minecraft.getInstance().gameRenderer.gameRenderState().windowRenderState.appropriateLineWidth;
        VoxelShape unit = Shapes.block();

        event.getRenderableSections().forEach(section -> {
            if (section.isEmpty()) {
                return;
            }
            poseStack.pushPose();
            poseStack.translate(
                    section.getRenderOrigin().getX() - camera.x,
                    section.getRenderOrigin().getY() - camera.y,
                    section.getRenderOrigin().getZ() - camera.z);
            // Disabled by default — enable after porting your draw logic.
            if (false) {
                event.getSubmitNodeCollector().submitShapeOutline(
                        poseStack, unit, RenderTypes.lines(), 0xFFFF0000, lineWidth, false);
            }
            poseStack.popPose();
        });
    }
}
"@
            [System.IO.File]::WriteAllText($outFile, $scaffoldBody.Trim() + "`r`n")
            $scaffold = $true
            $touched++
            $relScaffold = $outFile.Substring($javaRoot.Length).TrimStart('\', '/').Replace('\', '/')
            $hitFiles.Add($relScaffold) | Out-Null
        }
    }

    return @{
        touched  = $touched
        hits     = @($hitFiles | Select-Object -Unique)
        scaffold = $scaffold
    }
}

function Restore-ModAssets {
    <#
    .SYNOPSIS
      Decompiled 1.20.1 trees often have Java only. Purple/black items mean assets never copied.
      Pull assets/ + data/ from the source tree, a sibling jar, or the known-good 26.2 TOWW port.
    #>
    param([string]$Source, [string]$Dest, [string]$ModId, [string]$OriginalJarPath = '')

    $destRes = Join-Path $Dest 'src\main\resources'
    $existing = @(Get-ChildItem (Join-Path $destRes 'assets') -Recurse -Include '*.png','*.ogg','*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\items\\' })
    if ($existing.Count -gt 0) { return 0 }

    $copied = 0
    $jarHint = Join-Path $Source 'original-jar.txt'
    $jarFromHint = ''
    if ($OriginalJarPath -and (Test-Path -LiteralPath $OriginalJarPath)) {
        $jarFromHint = $OriginalJarPath
    } elseif (Test-Path -LiteralPath $jarHint) {
        $jarFromHint = (Get-Content -LiteralPath $jarHint -TotalCount 1).Trim()
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(
            (Join-Path $Source 'src\main\resources'),
            (Join-Path $Source 'resources')
        )) {
        if (Test-Path $p) { $candidates.Add($p) | Out-Null }
    }
    foreach ($resRoot in $candidates) {
        $assets = Join-Path $resRoot 'assets'
        if (-not (Test-Path $assets)) { continue }
        $ns = if ($ModId) { Join-Path $assets $ModId } else { $null }
        if ($ns -and -not (Test-Path $ns)) { continue }
        Copy-Item -LiteralPath $assets -Destination (Join-Path $destRes 'assets') -Recurse -Force
        $copied++
        $data = Join-Path $resRoot 'data'
        if (Test-Path $data) {
            Copy-Item -LiteralPath $data -Destination (Join-Path $destRes 'data') -Recurse -Force
        }
        $logo = Join-Path $resRoot 'logo.png'
        if (Test-Path $logo) { Copy-Item $logo $destRes -Force }
        Write-Ok "Restored assets from $resRoot"
        return $copied
    }

    $jarFiles = New-Object System.Collections.Generic.List[string]
    if ($jarFromHint -and (Test-Path -LiteralPath $jarFromHint)) { $jarFiles.Add($jarFromHint) | Out-Null }
    foreach ($dir in @($Source, (Split-Path $Source -Parent))) {
        if (-not (Test-Path $dir)) { continue }
        foreach ($jar in Get-ChildItem $dir -Filter '*.jar' -File -ErrorAction SilentlyContinue) {
            if (-not $jarFiles.Contains($jar.FullName)) { $jarFiles.Add($jar.FullName) | Out-Null }
        }
    }
    foreach ($jarPath in $jarFiles) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($jarPath)
            $hasAssets = $false
            foreach ($e in $zip.Entries) {
                if ($e.FullName -like 'assets/*') { $hasAssets = $true; break }
            }
            if (-not $hasAssets) { $zip.Dispose(); continue }
            foreach ($e in $zip.Entries) {
                if ($e.FullName.EndsWith('/')) { continue }
                if ($e.FullName -notmatch '^(assets|data)/' -and $e.FullName -notin @('logo.png', 'pack.png', 'pack.mcmeta')) { continue }
                $out = Join-Path $destRes ($e.FullName -replace '/', '\')
                $outDir = Split-Path $out -Parent
                if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
                $copied++
            }
            $zip.Dispose()
            if ($copied -gt 0) {
                Write-Ok "Restored $copied asset entries from $(Split-Path $jarPath -Leaf)"
                return $copied
            }
        } catch {
            Write-Warn2 "Asset jar extract failed $(Split-Path $jarPath -Leaf): $($_.Exception.Message)"
        }
    }
    Write-Warn2 'No textures/models found to restore — items/blocks will be purple/black in-game'
    return 0
}

function Invoke-ForgeConventionTagRewritePass {
    <#
    .SYNOPSIS
      Forge biome/item/block convention tags (`forge:is_cave`) are unbound on NeoForge 26.2.
      Tags.Biomes.IS_CAVE is `c:is_cave` (Identifier.fromNamespaceAndPath("c", name)).
      gecko_kings world-create crash: Unbound tags ... biome: [forge:is_cave].
    #>
    param([string]$Root)

    $res = Join-Path $Root 'src\main\resources'
    $java = Join-Path $Root 'src\main\java'
    $touched = 0
    $files = @()
    if (Test-Path -LiteralPath $res) {
        $files += @(Get-ChildItem -LiteralPath $res -Recurse -File -Include '*.json','*.mcmeta' -ErrorAction SilentlyContinue)
    }
    if (Test-Path -LiteralPath $java) {
        $files += @(Get-ChildItem -LiteralPath $java -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue)
    }
    foreach ($f in $files) {
        $t = [IO.File]::ReadAllText($f.FullName)
        $o = $t
        $t = $t.Replace('#forge:', '#c:')
        $t = $t -replace '(?<![\w])forge:(is_[a-z0-9_/]+)', 'c:$1'
        if ($t -ne $o) {
            [IO.File]::WriteAllText($f.FullName, $t)
            $touched++
        }
    }

    $forgeTags = Join-Path $res 'data\forge\tags'
    $cTags = Join-Path $res 'data\c\tags'
    if (Test-Path -LiteralPath $forgeTags) {
        New-Item -ItemType Directory -Path $cTags -Force | Out-Null
        Copy-Item -Path (Join-Path $forgeTags '*') -Destination $cTags -Recurse -Force
        $touched++
    }
    return $touched
}

function Invoke-Minecraft262RecipeIngredientPass {
    <#
    .SYNOPSIS
      26.2 Ingredient.CODEC accepts a registry-name string (or #tag), not legacy {"item":"..."} / {"tag":"..."} objects.
      MCreator 26.1.x datapack templates emit plain strings; 1.21.x jars still ship object ingredients → recipe parse errors.
      Evidence: Exact_Version_Sources/NeoForge/26.2 SizedIngredient docs ("ingredient": "minecraft:apple");
      MCreator generator-26.1.x datapack templates/recipe/crafting.json.ftl + smithing.json.ftl.
    #>
    param([string]$Root)

    $dataRoot = Join-Path $Root 'src\main\resources\data'
    if (-not (Test-Path -LiteralPath $dataRoot)) { return 0 }
    $touched = 0
    $recipeDirs = @(Get-ChildItem -LiteralPath $dataRoot -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'recipe' -or $_.Name -eq 'recipes' })
    foreach ($dir in $recipeDirs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
            $t = [IO.File]::ReadAllText($f.FullName)
            $o = $t
            # Pure single-key ingredient objects only (result stays {"id":...,"count":...}).
            $t = [regex]::Replace($t, '\{\s*"item"\s*:\s*"([^"]+)"\s*\}', '"$1"')
            $t = [regex]::Replace($t, '\{\s*"tag"\s*:\s*"#?([^"]+)"\s*\}', '"#$1"')
            if ($t -ne $o) {
                [IO.File]::WriteAllText($f.FullName, $t)
                $touched++
            }
        }
    }
    return $touched
}

function Invoke-Minecraft262TreeConfiguredFeaturePass {
    [CmdletBinding()]
    param([string]$Root)

    $dataRoot = Join-Path $Root 'src\main\resources\data'
    if (-not (Test-Path -LiteralPath $dataRoot)) { return 0 }
    $touched = 0
    $files = Get-ChildItem -LiteralPath $dataRoot -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/]worldgen[\\/]configured_feature[\\/]' }
    foreach ($file in @($files)) {
        $original = [IO.File]::ReadAllText($file.FullName)
        $converted = Convert-Minecraft262TreeConfiguredFeatureDocument -JsonText $original
        if ($converted -ne $original.TrimEnd()) {
            [IO.File]::WriteAllText($file.FullName, $converted)
            $touched++
        }
    }
    return $touched
}

function Invoke-Minecraft262ItemModelPass {
    <#
    .SYNOPSIS
      26.2 removed minecraft:item/template_spawn_egg (gecko_kings creative tab is mostly spawn eggs → purple/black).
      Namespace unprefixed item/block model parents and restore a two-layer spawn-egg template from 1.21.1.
    #>
    param([string]$Root, [string]$ToolRoot)

    $assetsRoot = Join-Path $Root 'src\main\resources\assets'
    if (-not (Test-Path -LiteralPath $assetsRoot)) { return 0 }
    $pack = Join-Path $ToolRoot 'lib\client-items'
    $eggPng = Join-Path $pack 'spawn_egg.png'
    $ovlPng = Join-Path $pack 'spawn_egg_overlay.png'
    $touched = 0

    foreach ($nsDir in @(Get-ChildItem -LiteralPath $assetsRoot -Directory -ErrorAction SilentlyContinue)) {
        $modid = $nsDir.Name
        $modelsItem = Join-Path $nsDir.FullName 'models\item'
        if (-not (Test-Path -LiteralPath $modelsItem)) { continue }
        $usedTemplate = $false
        foreach ($f in @(Get-ChildItem -LiteralPath $modelsItem -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $t = [IO.File]::ReadAllText($f.FullName)
            $o = $t
            if ($t -match '"parent"\s*:\s*"(?:minecraft:)?item/template_spawn_egg"') {
                $usedTemplate = $true
                $t = [regex]::Replace($t, '"parent"\s*:\s*"(?:minecraft:)?item/template_spawn_egg"', ('"parent": "' + $modid + ':item/template_spawn_egg"'))
            }
            $t = $t -replace '"parent"\s*:\s*"item/', '"parent": "minecraft:item/'
            $t = $t -replace '"parent"\s*:\s*"block/', '"parent": "minecraft:block/'
            if ($t -ne $o) {
                [IO.File]::WriteAllText($f.FullName, $t)
                $touched++
            }
        }
        $clientItems = Join-Path $nsDir.FullName 'items'
        foreach ($f in @(Get-ChildItem -LiteralPath $clientItems -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $original = [IO.File]::ReadAllText($f.FullName)
            $converted = Convert-Minecraft262ClientItemDocument -JsonText $original -ModId $modid
            if ($converted -ne $original.TrimEnd()) {
                $usedTemplate = $true
                [IO.File]::WriteAllText($f.FullName, $converted)
                $touched++
            } elseif ($converted -match [regex]::Escape("${modid}:item/template_spawn_egg")) {
                $usedTemplate = $true
            }
        }
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $nsDir.FullName 'models\block') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $t = [IO.File]::ReadAllText($f.FullName)
            $o = $t
            $t = $t -replace '"parent"\s*:\s*"item/', '"parent": "minecraft:item/'
            $t = $t -replace '"parent"\s*:\s*"block/', '"parent": "minecraft:block/'
            if ($t -ne $o) {
                [IO.File]::WriteAllText($f.FullName, $t)
                $touched++
            }
        }
        if ($usedTemplate -and (Test-Path -LiteralPath $eggPng) -and (Test-Path -LiteralPath $ovlPng)) {
            $texDir = Join-Path $nsDir.FullName 'textures\item'
            New-Item -ItemType Directory -Path $texDir -Force | Out-Null
            Copy-Item -LiteralPath $eggPng -Destination (Join-Path $texDir 'spawn_egg.png') -Force
            Copy-Item -LiteralPath $ovlPng -Destination (Join-Path $texDir 'spawn_egg_overlay.png') -Force
            $tmpl = "{`n  `"parent`": `"minecraft:item/generated`",`n  `"textures`": {`n    `"layer0`": `"${modid}:item/spawn_egg`",`n    `"layer1`": `"${modid}:item/spawn_egg_overlay`"`n  }`n}`n"
            [IO.File]::WriteAllText((Join-Path $modelsItem 'template_spawn_egg.json'), $tmpl)
            $touched++
        }
    }
    return $touched
}

function Ensure-ClientItems {
    param([string]$Root)
    $assets = Join-Path $Root 'src\main\resources\assets'
    if (-not (Test-Path $assets)) { return 0 }
    $n = 0
    foreach ($ns in Get-ChildItem $assets -Directory) {
        $modelsItem = Join-Path $ns.FullName 'models\item'
        if (-not (Test-Path $modelsItem)) { continue }
        $itemsDir = Join-Path $ns.FullName 'items'
        New-Item -ItemType Directory -Path $itemsDir -Force | Out-Null
        foreach ($m in Get-ChildItem $modelsItem -Filter '*.json') {
            $id = [IO.Path]::GetFileNameWithoutExtension($m.Name)
            $cp = Join-Path $itemsDir "$id.json"
            if (Test-Path $cp) { continue }
            $json = "{`r`n  `"model`": {`r`n    `"type`": `"minecraft:model`",`r`n    `"model`": `"$($ns.Name):item/$id`"`r`n  }`r`n}`r`n"
            [IO.File]::WriteAllText($cp, $json)
            $n++
        }
    }
    return $n
}

function Install-WrapperFromTowwOrMdk {
    param([string]$Root)
    # Use the station NeoForge 26.2 generator MDK as the sole wrapper authority.
    $candidates = @(
        'C:\GokuCodexAI\Data\Neoforge Generator Templates\neoforge_26.2_generator_template',
        'C:\GokuCodexAI\Data\Exact_Version_Sources\NeoForge\26.2',
        'C:\GokuCodexAI\Data\Neoforge26.2generatortemplate'
    )
    foreach ($ref in $candidates) {
        if ((Test-Path (Join-Path $ref 'gradlew.bat')) -and (Test-Path (Join-Path $ref 'gradle\wrapper'))) {
            Copy-Item (Join-Path $ref 'gradlew.bat') $Root -Force
            if (Test-Path (Join-Path $ref 'gradlew')) { Copy-Item (Join-Path $ref 'gradlew') $Root -Force }
            New-Item -ItemType Directory -Path (Join-Path $Root 'gradle\wrapper') -Force | Out-Null
            Copy-Item (Join-Path $ref 'gradle\wrapper\*') (Join-Path $Root 'gradle\wrapper') -Force
            Write-Ok "Gradle wrapper copied from $ref"
            return
        }
    }
    Write-Warn2 'No wrapper reference found - run gradle wrapper manually'
}

# -------------------- main --------------------
function Invoke-LegacyConversionMain {
$Source = (Resolve-Path -LiteralPath $Path).Path
if (-not (Test-Path (Join-Path $Source 'src'))) { throw "No src/ under $Source" }
$sourceProfile = Get-SourceProfile -Root $Source -VersionOverride $SourceVersion
if ($sourceProfile.Route -eq 'unsupported-fabric-quilt') {
    throw "Detected $($sourceProfile.Loader) input. This converter only migrates Forge/NeoForge mods; decompile-only mode is still available."
}

if (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) $OutputPath
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

Write-Host ''
Write-Host 'Legacy Java Converter - Forge 1.20.1 -> NeoForge 26.2 (EXPERIMENTAL)' -ForegroundColor White
Write-Host "  Source : $Source"
Write-Host "  Output : $OutputPath"
Write-Host "  Target : Minecraft $MinecraftVersion / NeoForge $NeoVersion"
Write-Host "  Intake : loader=$($sourceProfile.Loader) source=$($sourceProfile.SourceVersion) confidence=$($sourceProfile.Confidence) route=$($sourceProfile.Route)"
if ($DryRun) {
    Write-Host '  DryRun : yes (preview only - no files written)' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Would perform:' -ForegroundColor Cyan
    Write-Host "  1. Copy project tree from source -> output (excluding build/.gradle/.git)"
    Write-Host "  2. Read mods.toml / Gradle / imports; download official 26.2 deps; convert remaining required mods"
    Write-Host "  3. Write ModDevGradle 26.2 scaffold (build.gradle, settings.gradle, gradle.properties, mods.toml)"
    Write-Host "  4. Mechanical Forge->NeoForge rewrites + 26.2 API pass + registry/event bootstrap"
    Write-Host "  5. Client item stubs + Gradle wrapper bootstrap when available"
    if ($Compile) { Write-Host "  6. Run compileJava (diagnostic)" }
    Write-Host ''
    Write-Host "Source has src/: $((Test-Path (Join-Path $Source 'src')))" -ForegroundColor Green
    $javaCount = @(Get-ChildItem (Join-Path $Source 'src') -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue).Count
    Write-Host "Java files under src/: $javaCount" -ForegroundColor Green
    try {
        $cat = Get-DependencyCatalog
        $previewMeta = Get-ModMetaFromSource -Root $Source
        $previewDeps = Read-ProjectDependencies -Root $Source -SelfModId $previewMeta.mod_id -Catalog $cat
        Write-Host "Detected dependencies: $($previewDeps.Count)" -ForegroundColor Green
        foreach ($pd in $previewDeps) {
            Write-Host "    - $($pd.ModId) required=$($pd.Required) ($($pd.Source))"
        }
    } catch {
        Write-Warn2 "Dependency preview failed: $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host 'Dry run complete. Re-run without -DryRun to write files.' -ForegroundColor Yellow
    return
}

Write-Step 'Copying project (original preserved)'
$n = Copy-ProjectTree -Source $Source -Dest $OutputPath
Write-Ok "Copied $n files"

$meta = Get-ModMetaFromSource -Root $Source
Write-Info "mod_id=$($meta.mod_id) group=$($meta.mod_group) version=$($meta.mod_version)"

Write-Step 'Matching encoded completed solutions (SolvedConversionIndex)'
$sourceProfile = Merge-SolvedConversionsIntoProfile -Profile $sourceProfile -ModId $meta.mod_id
if (@($sourceProfile.AppliedSolutions).Count -gt 0) {
    foreach ($s in @($sourceProfile.AppliedSolutions)) {
        Write-Ok ("Solution {0}" -f $s.Id)
    }
} else {
    Write-Info 'No mod-specific solved case matched; band defaults may still apply.'
}
if ($sourceProfile.PSObject.Properties['SolvedStopMessage'] -and $sourceProfile.SolvedStopMessage) {
    Write-Warn2 ([string]$sourceProfile.SolvedStopMessage)
    throw ([string]$sourceProfile.SolvedStopMessage)
}

Write-SourceProfile -Profile $sourceProfile -Path (Join-Path $OutputPath 'SOURCE_PROFILE.json')
Write-Ok 'Wrote SOURCE_PROFILE.json (includes AppliedSolutions when matched)'
$primerSteps = Write-PrimerQuickReference -Profile $sourceProfile -Path (Join-Path $OutputPath 'PRIMER_CHANGE_INDEX.md')
Write-Ok "Wrote PRIMER_CHANGE_INDEX.md ($primerSteps applicable transition(s))"

if (-not $LocalLibDir) {
    $guess = Join-Path (Split-Path $Source -Parent) ''
    if (Test-Path (Join-Path $guess 'geckolib-neoforge-26.2-5.5.3.jar')) {
        $LocalLibDir = $guess.TrimEnd('\')
    }
}

Write-Step 'Reading and resolving dependencies (official 26.2 first, then convert required 1.20.1 mods)'
$catalog = Get-DependencyCatalog
$depRecords = Read-ProjectDependencies -Root $OutputPath -SelfModId $meta.mod_id -Catalog $catalog
Write-DetectedDependenciesJson -Path (Join-Path $OutputPath 'detected-dependencies.json') -Records $depRecords
Write-Info "Detected $($depRecords.Count) dependency record(s)"
foreach ($dr in $depRecords) {
    Write-Info ("  {0} required={1} source={2}" -f $dr.ModId, $dr.Required, $dr.Source)
}

Write-Step 'Building incremental migration evidence packet (NeoForge + hard deps)'
$converterVersionLabel = '2.10.3'
foreach ($vf in @(
        (Join-Path $ToolRoot '..\version.txt'),
        (Join-Path $ToolRoot 'version.txt'),
        (Join-Path (Split-Path $ToolRoot -Parent) 'version.txt')
    )) {
    if (Test-Path -LiteralPath $vf) {
        $converterVersionLabel = (Get-Content -LiteralPath $vf -TotalCount 1).Trim()
        if ($converterVersionLabel) { break }
    }
}
$migrationEvidence = Write-MigrationEvidencePacket `
    -Profile $sourceProfile `
    -OutputDirectory $OutputPath `
    -DependencyRecords $depRecords `
    -ConverterVersion $converterVersionLabel
$sourceProfile = Add-MigrationEvidenceToProfile -Profile $sourceProfile -EvidenceResult $migrationEvidence
Write-SourceProfile -Profile $sourceProfile -Path (Join-Path $OutputPath 'SOURCE_PROFILE.json')
Write-Ok ("Wrote MIGRATION_EVIDENCE.md/.json (claim {0}; neoforge={1}; geckolib={2}; mcreator={3})" -f `
        $migrationEvidence.ClaimStatus, `
        $migrationEvidence.NeoForge.LedgerSource, `
        $migrationEvidence.Signals.GeckoLib, `
        $migrationEvidence.Signals.MCreator)

$libsDir = Join-Path $OutputPath 'libs'
$cacheDir = Join-Path $ToolRoot 'lib\dep-cache'
$convertedDir = Join-Path $OutputPath 'converted-deps'
$localDirs = New-Object System.Collections.Generic.List[string]
foreach ($d in @($DependencyJarDir)) { if ($d) { $localDirs.Add($d) | Out-Null } }
$localDirs.Add((Split-Path $Source -Parent)) | Out-Null
$localDirs.Add((Join-Path $Source 'libs')) | Out-Null
$localDirs.Add((Join-Path $Source 'run\mods')) | Out-Null
if ($LocalLibDir) { $localDirs.Add($LocalLibDir) | Out-Null }

$visitedList = @($meta.mod_id)
if ($VisitedModIds) { $visitedList += ($VisitedModIds -split ',' | Where-Object { $_ }) }

$convertJarScript = Join-Path $ToolRoot 'Convert-OldJarToNeoForge262.ps1'
$sourceLibsDir = Join-Path $OutputPath 'libs-source'
$resolvedDeps = Resolve-AndAcquireDependencies `
    -Records $depRecords `
    -Catalog $catalog `
    -LibsDir $libsDir `
    -CacheDir $cacheDir `
    -ConvertedDepsDir $convertedDir `
    -LocalJarDirs @($localDirs) `
    -ConvertJarScript $convertJarScript `
    -MinecraftVersion $MinecraftVersion `
    -SourceMinecraftVersion $sourceProfile.SourceVersion `
    -SourceLibsDir $sourceLibsDir `
    -NeoVersion $NeoVersion `
    -GeckoLibVersion $GeckoLibVersion `
    -DependencyDepth $DependencyDepth `
    -MaxDependencyDepth $MaxDependencyDepth `
    -VisitedModIds $visitedList `
    -SkipDownload:$SkipDependencyDownload `
    -SkipConvert:$SkipDependencyConvert `
    -ConvertOptional:$ConvertOptionalDependencies

$depPlan = New-DependencyGradlePlan -Resolved $resolvedDeps
Write-DependencyReport -Path (Join-Path $OutputPath 'DEPENDENCY_REPORT.md') -Records $depRecords -Resolved $resolvedDeps
Write-Ok 'Wrote DEPENDENCY_REPORT.md'

Write-Step 'Writing NeoForge 26.2 Gradle scaffold + resolved dependency map'
Write-GradleScaffold -Root $OutputPath -Meta $meta -LocalLibs $LocalLibDir -DepPlan $depPlan
Write-Ok 'build.gradle / settings.gradle / gradle.properties / neoforge.mods.toml'

Write-Step 'Mechanical Java rewrites (Forge -> NeoForge, Identifier, ticks, GeckoLib5)'
$j = if (Test-MigrationPass $sourceProfile 'mechanical-java') { Invoke-MechanicalJavaRewrites -Root $OutputPath -ModId $meta.mod_id } else { 0 }
Write-Ok "Touched $j Java file(s)"

Write-Step 'Exact primer migration path (detected source -> 26.2)'
$exactPrimer = Invoke-ExactPrimerMigrationRules -Root $OutputPath -Profile $sourceProfile -ModId $meta.mod_id
Write-Ok ("Applied {0} version-gated rule(s); touched {1} unit(s)" -f @($exactPrimer.Rules).Count, $exactPrimer.Touched)

Write-Step 'NeoForge/Minecraft 26.2 API pass (NBT, nav, teleport, weather, colors, permissions)'
$api = if (Test-MigrationPass $sourceProfile 'neoforge-26-api') { Invoke-NeoForge26ApiRewritePass -Root $OutputPath } else { 0 }
Write-Ok "API-touched $api Java file(s)"

Write-Step 'Minecraft entity/item subpackage remap (1.21.11 primer: golem/npc/equine/ArmorType/Util/GameRules)'
$entityPkg = Invoke-MinecraftEntitySubpackageRemapPass -Root $OutputPath
Write-Ok "Entity-subpackage-touched $entityPkg Java file(s)"

Write-Step 'Minecraft 26.2 compile repair (GameRules/ArmorMaterial/SpawnEgg/Fog/Tier/Sound getValue)'
$compile262 = Invoke-Minecraft262CompileRepairPass -Root $OutputPath
Write-Ok "Compile-repair-touched $compile262 Java file(s)"

Write-Step 'Optional integration exclude (Carry On / Sable / missing soft deps)'
$optEx = Invoke-OptionalIntegrationExcludePass -Root $OutputPath
Write-Ok "Optional-integration-excluded $optEx file(s)"

Write-Step 'DFU / record / mixin Vineflower repair (RecordCodecBuilder validate accessors)'
$dfu = Invoke-DfuCodecRepairPass -Root $OutputPath
Write-Ok "DFU-repair-touched $dfu Java file(s)"

Write-Step 'SubmitCustomGeometryEvent scaffold (world MultiBufferSource / bufferSource / ShapeRenderer)'
$geom = Invoke-SubmitCustomGeometryPass -Root $OutputPath -Meta $meta
Write-Ok ("Geometry-pass units: {0}; scaffold written: {1}" -f $geom.touched, $geom.scaffold)

Write-Step 'MCreator / NeoForge 1.21.x -> 26.2 pass (blocks GUI menus fluid overlay)'
$m121 = if (Test-MigrationPass $sourceProfile 'mcreator-1.21.x') { Invoke-Mcreator1218ToNeoForge262Pass -Root $OutputPath } else { 0 }
Write-Ok "1.21.x-touched $m121 Java file(s)"

# MCreator 1.21.x can leave/reintroduce MobEffect + armor client leftovers after the earlier
# 262-repair pass (applyEffectTick ServerLevel, renderInventoryText, registerItemExtensions stub).
# Re-run compile repair so CASE-005 remaps stick on Mode B (idempotent for already-fixed files).
if ($m121 -gt 0) {
    Write-Step 'Minecraft 26.2 compile repair (post-MCreator leftover sweep)'
    $compile262b = Invoke-Minecraft262CompileRepairPass -Root $OutputPath
    Write-Ok "Post-MCreator compile-repair-touched $compile262b Java file(s)"
}

Write-Step 'MCreator 1.20.1 residue pass (overlay, food, SavedData, effects; MCP-verified SRG)'
$m120 = if (Test-MigrationPass $sourceProfile 'mcreator-1.20.1') { Invoke-McreatorForge1201ResiduePass -Root $OutputPath } else { 0 }
Write-Ok "1.20.1-residue-touched $m120 Java file(s)"

Write-Step 'ModConfigSpec order pass (define-before-build; prevents world-join disconnect)'
$cfg = if (Test-MigrationPass $sourceProfile 'config-order') { Invoke-ModConfigSpecOrderPass -Root $OutputPath } else { 0 }
Write-Ok "Config-order-touched $cfg file(s)"

Write-Step 'Registry template pass (createEntities / Registries.SOUND_EVENT / items / blocks)'
$r = if (Test-MigrationPass $sourceProfile 'registry') { Invoke-RegistryTemplatePass -Root $OutputPath } else { 0 }
Write-Ok "Registry-touched $r file(s)"

Write-Step 'Block/Item Properties.setId pass (registerBlock/registerItem; 26.2 NPE Block/Item id not set)'
$ids = if (Test-MigrationPass $sourceProfile 'block-item-id') { Invoke-BlockItemIdPass -Root $OutputPath } else { 0 }
Write-Ok "Block/Item-id-touched $ids Java file(s)"

Write-Step 'GeckoLib 5.5 texture + AnimationController pass (TOWW/Friend 26.2)'
$geo = if (Test-MigrationPass $sourceProfile 'geckolib') { Invoke-GeckoLib26Pass -Root $OutputPath } else { 0 }
Write-Ok "GeckoLib-touched $geo Java file(s)"

Write-Step 'Mod entry template pass (IEventBus + ModContainer injection)'
$m = if (Test-MigrationPass $sourceProfile 'mod-entry') { Invoke-ModEntryTemplatePass -Root $OutputPath } else { 0 }
Write-Ok "Mod-entry-touched $m file(s)"

Write-Step 'EventBusSubscriber -> explicit addListener bootstrap'
$e = if (Test-MigrationPass $sourceProfile 'event-bus') { Invoke-EventBusSubscriberPass -Root $OutputPath -Meta $meta } else { 0 }
Write-Ok "Event-bus pass touched $e unit(s) (classes + LegacyEventBootstrap)"

Write-Step 'Solved-conversion semantic overlays (final; after rewrite passes)'
$solvedOverlays = Apply-SolvedConversionOverlays -Root $OutputPath -Profile $sourceProfile -ModId $meta.mod_id -ToolRoot $ToolRoot
Write-Ok ("Overlays applied: {0}; files touched: {1}" -f ((@($solvedOverlays.Overlays) -join ', '), $solvedOverlays.Touched))

Write-Step 'Restore assets/data (decompiled trees are often Java-only)'
$assetsRestored = Restore-ModAssets -Source $Source -Dest $OutputPath -ModId $meta.mod_id -OriginalJarPath $OriginalJarPath
Write-Ok "Asset restore units: $assetsRestored"

Write-Step 'Forge convention tags -> c: (biome is_cave unbound on world create)'
$forgeTags = Invoke-ForgeConventionTagRewritePass -Root $OutputPath
Write-Ok "Forge-tag-rewrite-touched $forgeTags file(s)"

Write-Step '26.2 recipe ingredients: {"item"/"tag"} objects -> id / #tag strings'
$recipeIng = Invoke-Minecraft262RecipeIngredientPass -Root $OutputPath
Write-Ok "Recipe-ingredient-touched $recipeIng file(s)"

Write-Step 'Client item stubs (if models/item exist)'
$ci = Ensure-ClientItems -Root $OutputPath
Write-Ok "Created $ci client item file(s)"

Write-Step '26.2 item model parents + restore template_spawn_egg'
$itemModels = Invoke-Minecraft262ItemModelPass -Root $OutputPath -ToolRoot $ToolRoot
Write-Ok "Item-model-touched $itemModels file(s)"

Write-Step '26.2 tree configured_feature dirt_provider -> below_trunk_provider'
$treeCf = Invoke-Minecraft262TreeConfiguredFeaturePass -Root $OutputPath
Write-Ok "Tree-configured-feature-touched $treeCf file(s)"

Write-Step 'Gradle wrapper'
Install-WrapperFromTowwOrMdk -Root $OutputPath

$reportPath = Join-Path $OutputPath 'LEGACY_MIGRATION_REPORT.md'
$report = @"
# Legacy migration report: $($meta.mod_id)

- Source: ``$Source``
- Output: ``$OutputPath``
- Target: Minecraft $MinecraftVersion / NeoForge $NeoVersion
- Detected source: $($sourceProfile.SourceVersion) ($($sourceProfile.Loader), confidence $($sourceProfile.Confidence))
- Migration route: ``$($sourceProfile.Route)``
- Exact primer rules: ``$(@($exactPrimer.Rules) -join ', ')``
- Primer quick reference: ``PRIMER_CHANGE_INDEX.md``
- Incremental evidence: ``MIGRATION_EVIDENCE.md`` / ``MIGRATION_EVIDENCE.json`` (NeoForge primer_changes + GeckoLib/MCreator when signaled)
- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')

## What was automated

1. Full project copy (original unchanged)
2. ModDevGradle 26.2 scaffold (Java 25)
3. Dependency pipeline (see ``DEPENDENCY_REPORT.md``):
   - Read ``mods.toml`` / Gradle / jar-in-jar / Java imports
   - Download official NeoForge 26.2 artifacts (GeckoLib, SmartBrainLib, Modrinth 26.2 jars)
   - Recursively convert required Forge 1.20.1 mods that have no 26.2 build
   - Wire Maven coordinates and ``libs/*.jar`` into the Gradle scaffold
4. Mechanical package renames Forge -> NeoForge
5. Safer TickEvent rewrite (ClientTickEvent.Post / ServerTickEvent.Post)
6. ``ResourceLocation`` -> ``Identifier`` (MC 26.x rename)
7. GeckoLib 4 packages -> GeckoLib 5 (``com.geckolib`` + AnimationController ctor)
8. **26.2 API pass** (Friend + The Knocker): NBT OrEmpty, isSolidRender, PathNavigation.moveTo vs Entity.snapTo,
   EntitySpawnReason create, server via level().getServer(), BreakBlockEvent, permissions, ColorCollection blocks,
   weather/clock stubs, cross-dim teleport signature, Camera.position, ClipContext CollisionContext,
   displayClientMessage->sendSystemMessage, RespawnConfig.respawnData, getSpawnPos, CommandSourceStack PermissionSet,
   FMLEnvironment.getDist(), registerItem/SpawnEggItem, client RenderTypes/SubmitNodeCollector/ArmorModelSet
9. **MCreator / NeoForge 1.21.x pass** (MOAdecor BATH): drop ``shouldDisplayFluidOverlay`` / ``BlockAndTintGetter``,
   ``noCollission``->``noCollision``, ``GuiGraphics``->``GuiGraphicsExtractor``, container ``renderBg``->``extractBackground``,
   final ``imageWidth``/``imageHeight`` via ``super(..., w, h)``, ``keyPressed(KeyEvent)``, ``isClientSide()``,
   remove ``Tuple`` work-queue, stub broken ``ItemHandler.ITEM/ENTITY`` capability binds
10. **ModConfigSpec order pass** (define-before-build) ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â prevents world-join disconnect from decompiled MCreator configs
11. Registry templates (createEntities / Registries.SOUND_EVENT / createItems / createBlocks)
12. ``@Mod`` constructor injection template (IEventBus + ModContainer)
13. ``@Mod.EventBusSubscriber`` -> ``LegacyEventBootstrap`` + ``addListener`` registrations
14. Entity level accessors (safe ``this.level()`` only), getCenter, setMaxUpStep comment-out
15. pack.mcmeta format 107 + **templates/** neoforge.mods.toml (removes leftover resources META-INF toml that pins old MC versions)
16. Client item stubs where models/item existed

## Important

- Conversion success means a **scaffold** was written. It does **not** mean the mod is loadable yet.
- Only install jars produced by ``gradlew build`` from this output (``build/libs/*.jar``).
- Never rename the input 1.20.1 / 1.21.x jar and treat it as a 26.2 mod ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â NeoForge will reject old ``versionRange`` pins.

## What you must still fix manually

- GeckoLib 5 render/model method signatures (GeoRenderState) and remaining client ``submit`` layer bodies
- SmartBrainLib 1.x -> 2.x API if used
- Written books / dyed items (DataComponents) if used heavily
- Nested/multi-line teleportTo and complex expression rewrites
- Networking payload registrar typing, SavedDataType Identifier+Codec edge cases
- Capabilities transfer API (old ItemHandler registration is commented out)
- Mixins, worldgen datapacks
- SynchedEntityData.define builder APIs, entity tags, remaining vanilla package moves
- Full ``gradlew compileJava`` / ``build`` until clean

## Next commands

Gradle is pinned to the **destination JDK** (Java 25 for NeoForge 26.2) via ``org.gradle.java.home`` in ``gradle.properties``. Do not rely on a Java-8 ``JAVA_HOME``. Prefer the helper (agents must):

``````powershell
powershell -NoProfile -File "C:\GokuCodexAI\projects\RMCodexMCConverter\Build-WithDestinationJava.ps1" -ProjectRoot "$OutputPath"
``````

Or, after the pin is present:

``````powershell
cd "$OutputPath"
.\gradlew.bat compileJava --stacktrace
.\gradlew.bat build
``````

Local jars (optional install into mods for runClient):
- ``$LocalLibDir\geckolib-neoforge-26.2-5.5.3.jar``
- ``$LocalLibDir\smartbrainlib-neoforge-26.2-2.0.0.jar``
"@
[System.IO.File]::WriteAllText($reportPath, $report)

Write-Ok "Wrote $reportPath"

$compileExit = 0
if ($Compile) {
    Write-Step 'Running Gradle build (compile + tests/resources + versioned JAR)'
    try {
        $gradleRun = Invoke-GradleBuildWithRequiredJava -ProjectRoot $OutputPath -Tasks 'build --no-daemon --stacktrace' -FallbackJavaMajor 25
        $compileExit = [int]$gradleRun.ExitCode
        Write-Ok ("Gradle JAVA_HOME={0} (Java {1}; project requires {2}+)" -f $gradleRun.JavaHome, $gradleRun.SelectedMajor, $gradleRun.RequiredMajor)
        $null = Write-CompileDiagnosticSummary -LogPath $gradleRun.LogPath -ExitCode $compileExit
        Write-Host "Gradle exit: $compileExit"
        if ($compileExit -ne 0) {
            Write-Warn2 "Gradle build failed (exit $compileExit). Scaffold is still written."
            Write-Warn2 "See compile-errors.log in the output folder for details."
            try {
                $repairRequest = Write-CodexRepairRequest -FailedOutput $OutputPath -DestinationJavaMajor 25 -TargetMinecraft $MinecraftVersion
                Write-Ok "Wrote GokuCodexAI repair request (destination Java pin): $repairRequest"
            } catch {
                Write-Warn2 "Could not write CODEX_REPAIR_REQUEST.md: $($_.Exception.Message)"
            }
            if (Test-Path -LiteralPath $gradleRun.LogPath) {
                Get-Content -LiteralPath $gradleRun.LogPath -Tail 40 | ForEach-Object { Write-Host "    $_" }
            }
        } else {
            $built = @(Get-ChildItem -LiteralPath (Join-Path $OutputPath 'build\libs') -Filter '*.jar' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'sources|javadoc' })
            if ($built.Count -gt 0) {
                Write-Ok "Gradle build succeeded: $($built[0].FullName)"
            } else {
                $compileExit = 3
                Write-Warn2 'Gradle reported success but no installable JAR was found under build\libs.'
            }
        }
    } catch {
        $compileExit = 1
        Write-Warn2 "Gradle launch failed: $($_.Exception.Message)"
        Write-Warn2 'Scaffold is still written. Install the required JDK and rerun gradlew build.'
    }
}

Write-Host ''
Write-Host "Conversion scaffold complete: $OutputPath" -ForegroundColor Green
Write-Host 'Original unchanged.' -ForegroundColor Green
if ($Compile -and $compileExit -ne 0) {
    Write-Host "Note: requested build failed with exit $compileExit; the scaffold is available for repair." -ForegroundColor Yellow
}
# Always exit 0 after successful scaffold so GUI does not report hard failure for diagnostic compile
exit 0
}

if ($env:LEGACY_CONVERTER_LOAD_ONLY -ne '1') {
    Invoke-LegacyConversionMain
}

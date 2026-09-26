function ConvertTo-NormalizedMinecraftVersion {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $hits = [regex]::Matches($Value, '(?<![\d.])(?:1\.(?:20|21)\.\d+|2[2-6](?:\.\d+){1,3})(?![\d.])')
    if ($hits.Count -eq 0) { return '' }
    return $hits[0].Value
}

function ConvertTo-ExtendedPath([string]$Value) {
    if ($env:OS -ne 'Windows_NT') { return $Value }
    if ($Value.StartsWith('\\?\')) { return $Value }
    if ($Value.StartsWith('\\')) { return '\\?\UNC\' + $Value.TrimStart('\') }
    return '\\?\' + [IO.Path]::GetFullPath($Value)
}

function Copy-FileLongPath([string]$Source, [string]$Destination) {
    $src = ConvertTo-ExtendedPath $Source
    $dst = ConvertTo-ExtendedPath $Destination
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst)) | Out-Null
    [IO.File]::Copy($src, $dst, $true)
}

function Convert-LevelClientSideAccess([string]$Text) {
    # BlockEntity exposes getLevel(); Entity exposes level(). Keep both shapes
    # separate and make the conversion safe when a project is processed again.
    $thisAccessor = if ($Text -match '\bextends\s+(?:[\w.]+\.)?(?!BlockEntity\b)\w*Entity\b') { 'this.level().' } else { 'this.getLevel().' }
    $Text = $Text -replace '\bthis\.(?:level\(\)|getLevel\(\))\.', $thisAccessor
    $Text = $Text -replace '\bthis\.level\.isClientSide\s*\(\)', ($thisAccessor + 'isClientSide()')
    $Text = $Text -replace '\bthis\.level\.isClientSide\b(?!\s*\()', ($thisAccessor + 'isClientSide()')
    $Text = $Text -replace '\bthis\.level\.', $thisAccessor
    $Text = [regex]::Replace($Text, '(?<![\w.])(entity|friend|mob|living|player|target|owner|self)\.level\.isClientSide\s*\(\)', '$1.level().isClientSide()', 'IgnoreCase')
    $Text = [regex]::Replace($Text, '(?<![\w.])(entity|friend|mob|living|player|target|owner|self)\.level\.isClientSide\b(?!\s*\()', '$1.level().isClientSide()', 'IgnoreCase')
    $Text = [regex]::Replace($Text, '(?<![\w.])(entity|friend|mob|living|player|target|owner|self)\.level\.(?!isClientSide)', '$1.level().', 'IgnoreCase')
    return $Text
}

function Get-Legacy262CompatPackage {
    <#
    .SYNOPSIS
      JPMS-safe package for the mechanical Legacy262Compat bridge.
      Must be unique per mod: two converted jars exporting the same package
      fail module resolution (ResolutionException / split package).
    #>
    param([AllowEmptyString()][string]$ModId = '')
    $seg = ([string]$ModId).Trim().ToLowerInvariant() -replace '[^a-z0-9_]', '_'
    if ([string]::IsNullOrWhiteSpace($seg)) { $seg = 'shared' }
    if ($seg -match '^[0-9]') { $seg = "m_$seg" }
    return "rb.legacy.converter.compat.$seg"
}

function Convert-NeoForge262ApiMoves {
    param(
        [string]$Text,
        [AllowEmptyString()][string]$ModId = ''
    )
    $compatPkg = Get-Legacy262CompatPackage -ModId $ModId
    $compatFqcn = "$compatPkg.Legacy262Compat"

    # Mojang package reorganisations between the 1.21.x primer and 26.2.
    $Text = $Text.Replace(
        'net.minecraft.client.renderer.block.model.VariantMutator',
        'net.minecraft.client.renderer.block.dispatch.VariantMutator')
    $Text = $Text.Replace(
        'net.minecraft.client.renderer.block.model.BlockStateModel',
        'net.minecraft.client.renderer.block.dispatch.BlockStateModel')
    $Text = $Text.Replace(
        'net.minecraft.client.renderer.state.CameraRenderState',
        'net.minecraft.client.renderer.state.level.CameraRenderState')

    # StateHolder#getValues now returns Stream<Property.Value<?>>.
    $Text = [regex]::Replace($Text,
        'for\s*\(\s*Entry<Property<\?>,\s*Comparable<\?>>\s+(\w+)\s*:\s*([^\r\n]+?)\.getValues\(\)\.entrySet\(\)\s*\)',
        'for (Property.Value<?> $1 : $2.getValues().toList())')
    $Text = $Text.Replace('entry.getKey()', 'entry.property()')
    $Text = $Text.Replace('entry.getValue()', 'entry.value()')

    # 26.2 tag appenders accept registry keys instead of item instances.
    $Text = [regex]::Replace($Text,
        '\.add\(([^\r\n;]+?\.asItem\(\))\)',
        '.add($1.builtInRegistryHolder().key())')

    if ($Text -match 'implements\s+BlockEntityRenderer') {
        $Text = $Text.Replace('super.extractRenderState(', 'BlockEntityRenderer.super.extractRenderState(')
    }
    $Text = [regex]::Replace($Text,
        'LevelRenderer\.getLightColor\(([^,]+),\s*([^)]+)\)',
        'net.minecraft.util.LightCoordsUtil.getLightCoords($1, $2)')

    # Standalone model registration must be explicitly typed in 26.2; an
    # untyped lifecycle listener otherwise resolves to the base Event class.
    if ($Text -match 'SimpleUnbakedStandaloneModel\.blockStateModel') {
        $Text = [regex]::Replace($Text, 'modEventBus\.addListener\(\s*e\s*->', 'modEventBus.addListener((net.neoforged.neoforge.client.event.ModelEvent.RegisterStandalone e) ->', 1)
    }

    # Rewrite any prior shared FQCN before inserting new references.
    $Text = $Text.Replace('rb.legacy.converter.compat.Legacy262Compat', $compatFqcn)

    # Renderer submission now consumes model parts and tint arrays.
    $Text = [regex]::Replace($Text,
        'submitBlockModel\(\s*([^,]+),\s*([^,]+),\s*(.+?),\s*1\.0F,\s*1\.0F,\s*1\.0F,\s*([^,]+),\s*([^,]+),\s*([^\)]+)\)',
        "submitBlockModel(`$1, `$2, $compatFqcn.modelParts(`$3), new int[0], `$4, `$5, `$6)",
        'Singleline')
    $Text = $Text.Replace('_bs.setValue(_property, entry.value())', "$compatFqcn.copyValue(_bs, entry)")
    return $Text
}

function Convert-ColorCollectionConstants([string]$Text) {
    $colors = [ordered]@{
        'WHITE'='white'; 'ORANGE'='orange'; 'MAGENTA'='magenta'; 'LIGHT_BLUE'='lightBlue'; 'YELLOW'='yellow'; 'LIME'='lime'
        'PINK'='pink'; 'GRAY'='gray'; 'LIGHT_GRAY'='lightGray'; 'CYAN'='cyan'; 'PURPLE'='purple'; 'BLUE'='blue'
        'BROWN'='brown'; 'GREEN'='green'; 'RED'='red'; 'BLACK'='black'
    }
    $groups = @(
        @{ Suffix='STAINED_GLASS_PANE'; Collection='STAINED_GLASS_PANE' }, @{ Suffix='CONCRETE_POWDER'; Collection='CONCRETE_POWDER' }
        @{ Suffix='GLAZED_TERRACOTTA'; Collection='GLAZED_TERRACOTTA' }, @{ Suffix='SHULKER_BOX'; Collection='DYED_SHULKER_BOX' }
        @{ Suffix='STAINED_GLASS'; Collection='STAINED_GLASS' }, @{ Suffix='TERRACOTTA'; Collection='DYED_TERRACOTTA' }
        @{ Suffix='CONCRETE'; Collection='CONCRETE' }, @{ Suffix='CARPET'; Collection='CARPET' }, @{ Suffix='BUNDLE'; Collection='DYED_BUNDLE' }
        @{ Suffix='HARNESS'; Collection='HARNESS' }, @{ Suffix='CANDLE'; Collection='DYED_CANDLE' }, @{ Suffix='BANNER'; Collection='BANNER' }
        @{ Suffix='WOOL'; Collection='WOOL' }, @{ Suffix='BED'; Collection='BED' }, @{ Suffix='DYE'; Collection='DYE' }
    ) | Sort-Object { $_.Suffix.Length } -Descending
    foreach ($group in $groups) {
        foreach ($color in $colors.Keys) {
            $Text = $Text.Replace("Items.${color}_$($group.Suffix)", "Items.$($group.Collection).$($colors[$color])()")
            $Text = $Text.Replace("Blocks.${color}_$($group.Suffix)", "Blocks.$($group.Collection).$($colors[$color])()")
        }
    }
    $Text = [regex]::Replace($Text, '\bBlocks\.CHAIN\b', 'Blocks.IRON_CHAIN')
    $Text = [regex]::Replace($Text, '\bItems\.CHAIN\b', 'Items.IRON_CHAIN')
    return $Text
}

function Get-MigrationRoute {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$SourceVersion, [AllowEmptyString()][string]$Loader)
    $v = ConvertTo-NormalizedMinecraftVersion $SourceVersion
    if ($Loader -match 'fabric|quilt') { return 'unsupported-fabric-quilt' }
    if ($v -eq '1.20.1') { return 'forge-1.20.1' }
    if ($v -match '^1\.20\.[2-4]$') { return 'forge-1.20.2-1.20.4' }
    if ($v -match '^1\.21\.') { return 'neoforge-1.21.x' }
    if ($v -match '^2[2-5]\.\d+') { return 'neoforge-22-to-25' }
    if ($v -match '^26\.[01](?:\.|$)') { return 'neoforge-26.0-26.1' }
    if ($v -eq '26.2' -or $v -match '^26\.2\.') { return 'already-26.2' }
    return 'generic-forge-neoforge'
}

function Get-RecommendedMigrationPasses {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Route)
    $common = @('mechanical-java', 'neoforge-26-api', 'config-order', 'registry', 'block-item-id', 'geckolib', 'mod-entry', 'event-bus', 'assets')
    switch ($Route) {
        'forge-1.20.1'       { return @('srg-1.20.1') + $common + @('mcreator-1.20.1') }
        'forge-1.20.2-1.20.4' { return $common + @('mcreator-1.20.1') }
        'neoforge-1.21.x'    { return $common + @('mcreator-1.21.x') }
        'neoforge-22-to-25'  { return $common }
        'neoforge-26.0-26.1' { return $common }
        'already-26.2'       { return @('config-order', 'registry', 'block-item-id', 'assets') }
        'unsupported-fabric-quilt' { return @('assets') }
        default              { return $common + @('mcreator-1.20.1', 'mcreator-1.21.x') }
    }
}

function Test-MigrationPass {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$Name)
    return @($Profile.RecommendedPasses) -contains $Name
}

function Get-ApiFeatureInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $rules = @(
        [pscustomobject]@{ Id='forge-packages'; Pass='mechanical-java'; Pattern='net\.minecraftforge\.'; Description='Forge package imports' }
        [pscustomobject]@{ Id='resource-location'; Pass='mechanical-java'; Pattern='\bResourceLocation\b'; Description='ResourceLocation API renamed for 26.x' }
        [pscustomobject]@{ Id='legacy-tick-events'; Pass='mechanical-java'; Pattern='TickEvent\.(?:ClientTickEvent|ServerTickEvent)'; Description='Legacy tick event shape' }
        [pscustomobject]@{ Id='legacy-nbt-access'; Pass='neoforge-26-api'; Pattern='getCompound\s*\('; Description='Legacy compound NBT access' }
        [pscustomobject]@{ Id='display-client-message'; Pass='neoforge-26-api'; Pattern='displayClientMessage\s*\('; Description='Legacy player message call' }
        [pscustomobject]@{ Id='event-bus-subscriber'; Pass='event-bus'; Pattern='@Mod\.EventBusSubscriber'; Description='Annotation event-bus bootstrap' }
        [pscustomobject]@{ Id='deferred-register'; Pass='registry'; Pattern='\bDeferredRegister\b'; Description='Deferred registry API' }
        [pscustomobject]@{ Id='legacy-geckolib'; Pass='geckolib'; Pattern='software\.bernie\.geckolib|AnimationController\s*<[^>]+>\s*\('; Description='GeckoLib 4 API' }
        [pscustomobject]@{ Id='mcreator-source'; Pass='mcreator-1.21.x'; Pattern='net\.mcreator\.'; Description='MCreator-generated source' }
        [pscustomobject]@{ Id='legacy-gui-graphics'; Pass='mcreator-1.21.x'; Pattern='\bGuiGraphics\b|renderBg\s*\('; Description='Pre-26.2 GUI rendering API' }
        [pscustomobject]@{ Id='legacy-srg-name'; Pass='mcreator-1.20.1'; Pattern='\b(?:m_\d+_|f_\d+_)\b'; Description='Forge 1.20.1 SRG names' }
        [pscustomobject]@{ Id='legacy-capability'; Pass='neoforge-26-api'; Pattern='ForgeCapabilities|IItemHandler|registerBlockEntity\s*\('; Description='Legacy capability/item handler API' }
    )
    $hits = New-Object System.Collections.Generic.List[object]
    $javaRoot = Join-Path $Root 'src\main\java'
    if (-not (Test-Path $javaRoot)) { $javaRoot = $Root }
    foreach ($file in @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue)) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($rule in $rules) {
            if ($text -notmatch $rule.Pattern) { continue }
            if (-not ($hits | Where-Object Id -eq $rule.Id)) {
                $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/')
                $hits.Add([pscustomobject]@{ Id=$rule.Id; Pass=$rule.Pass; Description=$rule.Description; ExampleFile=$relative }) | Out-Null
            }
        }
    }
    return $hits.ToArray()
}

function Get-SourceProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [AllowEmptyString()][string]$VersionOverride = '')

    $evidence = New-Object System.Collections.Generic.List[object]
    $candidates = New-Object System.Collections.Generic.List[object]
    $loader = 'unknown'
    $framework = 'unknown'
    function Add-Candidate([string]$Version, [int]$Weight, [string]$Source, [string]$Detail) {
        $normalized = ConvertTo-NormalizedMinecraftVersion $Version
        if (-not $normalized) { return }
        $candidates.Add([pscustomobject]@{ Version = $normalized; Weight = $Weight; Source = $Source }) | Out-Null
        $evidence.Add([pscustomobject]@{ Source = $Source; Value = $normalized; Detail = $Detail }) | Out-Null
    }

    if ($VersionOverride) { Add-Candidate $VersionOverride 100 'override' 'Explicit -SourceVersion value' }
    $preservedProfile = Join-Path $Root 'SOURCE_PROFILE.json'
    if (Test-Path -LiteralPath $preservedProfile) {
        try {
            $prior = Get-Content -LiteralPath $preservedProfile -Raw | ConvertFrom-Json
            if ($prior.SourceVersion) { Add-Candidate ([string]$prior.SourceVersion) 95 'preserved source profile' 'SOURCE_PROFILE.json' }
            if ($prior.Loader) { $loader = [string]$prior.Loader }
            if ($prior.Framework) { $framework = [string]$prior.Framework }
        } catch { }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'gradle.properties' -ErrorAction SilentlyContinue | Select-Object -First 3)) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        foreach ($pattern in @('(?m)^\s*source_minecraft_version\s*=\s*([^\r\n#]+)', '(?m)^\s*minecraft_version\s*=\s*([^\r\n#]+)', '(?m)^\s*minecraftVersion\s*=\s*([^\r\n#]+)')) {
            $m = [regex]::Match($text, $pattern)
            if ($m.Success) {
                $weight = if ($pattern -match 'source_minecraft') { 95 } else { 90 }
                Add-Candidate $m.Groups[1].Value $weight 'gradle.properties' $file.Name
                break
            }
        }
        if ($text -match '(?im)^\s*(?:neo_version|neoforge_version)\s*=') { $loader = 'neoforge' }
        elseif ($text -match '(?im)^\s*forge_version\s*=') { $loader = 'forge' }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('mods.toml', 'neoforge.mods.toml') } | Select-Object -First 8)) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($file.Name -eq 'neoforge.mods.toml') { $loader = 'neoforge' } elseif ($loader -eq 'unknown') { $loader = 'forge' }
        foreach ($block in [regex]::Matches($text, '(?is)\[\[dependencies\.[^\]]+\]\](.*?)(?=\[\[|\z)')) {
            if ($block.Value -notmatch '(?im)^\s*modId\s*=\s*["'']minecraft["'']') { continue }
            $range = [regex]::Match($block.Value, '(?im)^\s*versionRange\s*=\s*["'']([^"'']+)["'']')
            if ($range.Success) { Add-Candidate $range.Groups[1].Value 85 'mod metadata' $file.Name }
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('build.gradle', 'build.gradle.kts') } | Select-Object -First 5)) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        foreach ($m in [regex]::Matches($text, '(?:net\.neoforged:neoforge:|minecraft_version\s*[=:]\s*["'']?)(1\.20\.1|1\.21\.\d+|2[2-6]\.\d+(?:\.\d+)?)')) { Add-Candidate $m.Groups[1].Value 70 'build script' $file.Name }
        if ($text -match 'net\.neoforged|moddevgradle|neoForge') { $loader = 'neoforge' } elseif ($text -match 'net\.minecraftforge|ForgeGradle') { $loader = 'forge' }
    }

    if (Test-Path (Join-Path $Root 'fabric.mod.json')) { $loader = 'fabric' }
    if (Test-Path (Join-Path $Root 'quilt.mod.json')) { $loader = 'quilt' }
    $javaRoot = Join-Path $Root 'src\main\java'
    if (Test-Path $javaRoot) {
        foreach ($file in @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue | Select-Object -First 300)) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($text -match 'net\.mcreator\.') { $framework = 'mcreator' }
            if ($loader -eq 'unknown' -and $text -match 'net\.neoforged\.') { $loader = 'neoforge' }
            if ($loader -eq 'unknown' -and $text -match 'net\.minecraftforge\.') { $loader = 'forge' }
        }
    }

    $selected = $candidates | Sort-Object Weight -Descending | Select-Object -First 1
    $sourceVersion = if ($selected) { $selected.Version } else { 'unknown' }
    $confidence = if (-not $selected) { 'low' } elseif ($selected.Weight -ge 85) { 'high' } else { 'medium' }
    $route = Get-MigrationRoute -SourceVersion $sourceVersion -Loader $loader
    $recommended = @(Get-RecommendedMigrationPasses -Route $route)
    $features = @(Get-ApiFeatureInventory -Root $Root)
    # Feature evidence supplements metadata. This is especially important for
    # decompiled or mixed-version projects whose manifest range is missing.
    foreach ($feature in $features) {
        if ($recommended -notcontains $feature.Pass -and $route -notin @('already-26.2', 'unsupported-fabric-quilt')) {
            $recommended += $feature.Pass
        }
    }
    [pscustomobject]@{
        SchemaVersion = 1; SourceVersion = $sourceVersion; Loader = $loader; Framework = $framework
        Confidence = $confidence; Route = $route
        RecommendedPasses = @($recommended); ApiFeatures = @($features)
        Evidence = $evidence.ToArray()
    }
}

function Write-SourceProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$Path)
    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $Profile | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-PrimerChangeIndex {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot 'PrimerChangeIndex.json'))
    if (-not (Test-Path -LiteralPath $Path)) { throw "Primer change index missing: $Path" }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-PrimerMigrationChain {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceVersion, $Index = (Get-PrimerChangeIndex))
    $normalized = ConvertTo-NormalizedMinecraftVersion $SourceVersion
    if ($normalized) { $SourceVersion = $normalized }
    $aliases = @{
        '1.20.2'='1.20.1'; '1.20.3'='1.20.1'; '1.20.4'='1.20.4'; '1.21.0'='1.21'
        '1.21.2'='1.21.2/3'; '1.21.3'='1.21.2/3'
        '26.1.1'='26.1'; '26.1.2'='26.1'
    }
    $start = if ($SourceVersion -match '^2[2-5]\.' -or $SourceVersion -match '^26\.[01](?:\.|$)') {
        '26.1'
    } elseif ($aliases.ContainsKey($SourceVersion)) {
        $aliases[$SourceVersion]
    } else {
        $SourceVersion
    }
    $all = @($Index.transitions)
    $position = -1
    for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i].from -eq $start) { $position = $i; break } }
    if ($SourceVersion -match '^26\.2(?:\.|$)') { return @() }
    if ($position -lt 0) { return @() }
    return @($all[$position..($all.Count - 1)])
}

function Get-PrimerMigrationRules {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceVersion, $Index = (Get-PrimerChangeIndex))
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $result = New-Object Collections.Generic.List[string]
    foreach ($transition in @(Get-PrimerMigrationChain -SourceVersion $SourceVersion -Index $Index)) {
        $ruleProperty = $transition.PSObject.Properties['rules']
        $transitionRules = if ($null -ne $ruleProperty) { @($ruleProperty.Value) } else { @() }
        foreach ($rule in $transitionRules) {
            if ($rule -and $seen.Add([string]$rule)) { $result.Add([string]$rule) | Out-Null }
        }
    }
    return $result.ToArray()
}

function Convert-CustomBlockRegistrationText {
    param([Parameter(Mandatory)][string]$Text)
    # NeoForge 26.2: custom Supplier-based registerBlock helpers construct blocks before
    # the registry key is known, which crashes with "Block id not set". Convert the helper
    # to DeferredRegister.Blocks.registerBlock's Function<Properties, T> form so setId is injected.
    if ($Text -notmatch 'DeferredRegister\.createBlocks\(' -or
        $Text -notmatch 'registerBlock\(String name, Supplier<T> block\)') { return $Text }
    $Text = $Text.Replace('import java.util.function.Supplier;', 'import java.util.function.Function;')
    $Text = $Text.Replace('registerBlock(String name, Supplier<T> block)', 'registerBlock(String name, Function<Properties, T> block)')
    $Text = $Text.Replace('BLOCKS.register(name, block)', 'BLOCKS.registerBlock(name, block)')
    $Text = [regex]::Replace($Text, '(registerBlock\(\s*"[^"]+"\s*,\s*)\(\)\s*->\s*new ', '$1properties -> new ')
    $Text = $Text.Replace('Properties.of()', 'properties')
    $Text = [regex]::Replace($Text,
        'ModItems\.ITEMS\.register\(name,\s*\(\)\s*->\s*new BlockItem\(\(Block\)block\.get\(\),\s*new net\.minecraft\.world\.item\.Item\.Properties\(\)\)\)',
        'ModItems.ITEMS.registerItem(name, properties -> new BlockItem((Block)block.get(), properties))')
    return $Text
}

function Get-SolvedConversionIndex {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot 'SolvedConversionIndex.json'))
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Test-SolvedVersionMatch {
    param([string]$SourceVersion, [string[]]$Versions, [string[]]$Aliases = @())
    if (-not $SourceVersion) { return $false }
    $all = @($Versions) + @($Aliases) | Where-Object { $_ }
    foreach ($v in $all) {
        if ($SourceVersion -eq $v) { return $true }
        # allow 26.1.2 to match band entry 26.1 when listed explicitly only; exact list match preferred
    }
    return $false
}

function Find-MatchingSolvedConversions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [AllowEmptyString()][string]$ModId = '',
        $Index = (Get-SolvedConversionIndex)
    )
    if (-not $Index) { return @() }
    $src = [string]$Profile.SourceVersion
    $loader = [string]$Profile.Loader
    $mod = ([string]$ModId).Trim().ToLowerInvariant()
    $matches = New-Object System.Collections.Generic.List[object]

    foreach ($sol in @($Index.solutions)) {
        $modIds = @($sol.modIds | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $versions = @($sol.sourceVersions)
        $aliases = @()
        if ($sol.PSObject.Properties['sourceVersionAliases']) { $aliases = @($sol.sourceVersionAliases) }
        $modOk = (-not $mod) -or ($modIds -contains $mod)
        $verOk = Test-SolvedVersionMatch -SourceVersion $src -Versions $versions -Aliases $aliases
        if ($modOk -and $verOk) { $matches.Add($sol) | Out-Null }
    }

    # Band defaults apply even without a specific mod match.
    foreach ($band in @($Index.bandDefaults)) {
        $versions = @($band.matchSourceVersions)
        $loaders = @($band.matchLoaders)
        $verOk = Test-SolvedVersionMatch -SourceVersion $src -Versions $versions
        $loaderOk = (-not $loaders -or $loaders.Count -eq 0 -or ($loaders | Where-Object { $_ -eq $loader }))
        if ($verOk -and $loaderOk) { $matches.Add($band) | Out-Null }
    }
    return $matches.ToArray()
}

function Merge-SolvedConversionsIntoProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [AllowEmptyString()][string]$ModId = '',
        $Index = (Get-SolvedConversionIndex)
    )
    $matched = @(Find-MatchingSolvedConversions -Profile $Profile -ModId $ModId -Index $Index)
    $passes = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Profile.RecommendedPasses)) { if ($p -and -not ($passes -contains $p)) { $passes.Add([string]$p) | Out-Null } }
    $transforms = New-Object System.Collections.Generic.List[string]
    $applied = New-Object System.Collections.Generic.List[object]
    $stopMessage = $null

    foreach ($m in $matched) {
        foreach ($p in @($m.forcePasses)) {
            if ($p -and -not ($passes -contains $p)) { $passes.Add([string]$p) | Out-Null }
        }
        foreach ($t in @($m.transforms)) {
            if ($t -and -not ($transforms -contains $t)) { $transforms.Add([string]$t) | Out-Null }
        }
        if ($m.PSObject.Properties['stopWithMessage'] -and $m.stopWithMessage) {
            $stopMessage = [string]$m.stopWithMessage
        }
        $applied.Add([pscustomobject]@{
            Id = $(if ($m.id) { [string]$m.id } else { 'unknown' })
            Notes = $(if ($m.PSObject.Properties['notes']) { [string]$m.notes } else { '' })
        }) | Out-Null
    }

    # Rebuild a plain PSCustomObject so JSON serialization and Add-Member stay stable
    # (generic List[T] NoteProperty values can throw "Argument types do not match").
    $out = [pscustomobject]@{
        SchemaVersion     = $(if ($Profile.PSObject.Properties['SchemaVersion']) { $Profile.SchemaVersion } else { 1 })
        SourceVersion     = [string]$Profile.SourceVersion
        Loader            = [string]$Profile.Loader
        Framework         = $(if ($Profile.PSObject.Properties['Framework']) { [string]$Profile.Framework } else { 'unknown' })
        Confidence        = $(if ($Profile.PSObject.Properties['Confidence']) { [string]$Profile.Confidence } else { 'medium' })
        Route             = $(if ($Profile.PSObject.Properties['Route']) { [string]$Profile.Route } else { '' })
        RecommendedPasses = @($passes)
        ApiFeatures       = @($(if ($Profile.PSObject.Properties['ApiFeatures']) { $Profile.ApiFeatures } else { @() }))
        Evidence          = @($(if ($Profile.PSObject.Properties['Evidence']) { $Profile.Evidence } else { @() }))
        SolvedTransforms  = @($transforms)
        AppliedSolutions  = @($applied.ToArray())
    }
    if ($stopMessage) {
        $out | Add-Member -NotePropertyName SolvedStopMessage -NotePropertyValue ([string]$stopMessage)
    }
    return $out
}

function Apply-SolvedConversionOverlays {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Profile,
        [AllowEmptyString()][string]$ModId = '',
        [string]$ToolRoot = $PSScriptRoot,
        $Index = (Get-SolvedConversionIndex)
    )
    $matched = @(Find-MatchingSolvedConversions -Profile $Profile -ModId $ModId -Index $Index)
    $touched = 0
    $appliedOverlays = New-Object System.Collections.Generic.List[string]
    foreach ($m in $matched) {
        if (-not $m.PSObject.Properties['overlays']) { continue }
        foreach ($ov in @($m.overlays)) {
            $overlayRel = [string]$ov.path
            if (-not $overlayRel) { continue }
            # ToolRoot is the converter tools/repo root (contains Convert-*.ps1 and lib/).
            # Overlay may be a directory or a .zip (zip avoids Windows MAX_PATH in installers).
            $overlayPath = Join-Path $ToolRoot (Join-Path 'lib\overlays' ($overlayRel -replace '/', '\'))
            if (-not (Test-Path -LiteralPath $overlayPath) -and (Split-Path $ToolRoot -Leaf) -eq 'lib') {
                $overlayPath = Join-Path $ToolRoot (Join-Path 'overlays' ($overlayRel -replace '/', '\'))
            }
            if (-not (Test-Path -LiteralPath $overlayPath)) { continue }

            $ok = $true
            if ($ov.PSObject.Properties['requireAnyFile']) {
                $ok = $false
                foreach ($req in @($ov.requireAnyFile)) {
                    $candidate = Join-Path $Root (($req -replace '/', [IO.Path]::DirectorySeparatorChar))
                    if (Test-Path -LiteralPath $candidate) { $ok = $true; break }
                }
            }
            if (-not $ok) { continue }

            $overlayWork = $overlayPath
            $tempExtract = $null
            if ($overlayPath -like '*.zip') {
                $tempExtract = Join-Path ([IO.Path]::GetTempPath()) ('rb-overlay-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($overlayPath, $tempExtract)
                $overlayWork = $tempExtract
            }

            try {
                $deleteList = Join-Path $overlayWork 'DELETE.txt'
                if (Test-Path -LiteralPath $deleteList) {
                    foreach ($line in @(Get-Content -LiteralPath $deleteList -ErrorAction SilentlyContinue)) {
                        $relDel = ([string]$line).Trim()
                        if (-not $relDel -or $relDel.StartsWith('#')) { continue }
                        $target = Join-Path $Root ($relDel -replace '/', [IO.Path]::DirectorySeparatorChar)
                        if (Test-Path -LiteralPath $target) {
                            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                            $touched++
                        }
                    }
                }

                foreach ($file in @(Get-ChildItem -LiteralPath $overlayWork -Recurse -File -ErrorAction SilentlyContinue)) {
                    if ($file.Name -eq 'DELETE.txt') { continue }
                    $relative = $file.FullName.Substring($overlayWork.Length).TrimStart('\', '/')
                    Copy-FileLongPath -Source $file.FullName -Destination (Join-Path $Root $relative)
                    $touched++
                }
                $appliedOverlays.Add($overlayRel) | Out-Null
            }
            finally {
                if ($tempExtract -and (Test-Path -LiteralPath $tempExtract)) {
                    Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    return [pscustomobject]@{ Touched = $touched; Overlays = @($appliedOverlays) }
}

function Write-PrimerQuickReference {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$Path)
    $chain = @(Get-PrimerMigrationChain -SourceVersion ([string]$Profile.SourceVersion))
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Primer change quick reference') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add("Detected source: **$($Profile.SourceVersion)**; target: **26.2**; route: ``$($Profile.Route)``.") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('This is a condensed change index, not a replacement for the linked official primers. Only transitions after the detected source are included.') | Out-Null
    foreach ($step in $chain) {
        $lines.Add('') | Out-Null
        $lines.Add("## $($step.from) â†’ $($step.to)") | Out-Null
        $lines.Add('') | Out-Null
        $sourceLabel = if ($step.sourceType -eq 'official-primer') { "[Official primer]($($step.officialPrimer))" } else { 'Converter-maintained bridge (no official primer published for this interval)' }
        $lines.Add("Source: $sourceLabel") | Out-Null
        foreach ($change in @($step.changes)) { $lines.Add("- $change") | Out-Null }
        if (@($step.passes).Count -gt 0) { $lines.Add("- Converter passes: ``$(@($step.passes) -join '`, `')``") | Out-Null }
    }
    [IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"))
    return $chain.Count
}

function Get-StationKnowledgeRoot {
    [CmdletBinding()]
    param([string]$Override = '')
    if ($Override -and (Test-Path -LiteralPath $Override)) {
        return (Resolve-Path -LiteralPath $Override).Path
    }
    foreach ($candidate in @(
            $env:GOKUCODEXAI_DATA,
            'C:\GokuCodexAI\Data'
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-BundledPrimerChangesRoot {
    return (Join-Path $PSScriptRoot 'primer_changes')
}

function Get-BundledDepChangesRoot {
    return (Join-Path $PSScriptRoot 'dep_changes')
}

function ConvertTo-VersionRank {
    param([string]$Version)
    $t = ConvertTo-NormalizedMinecraftVersion $Version
    if (-not $t) { $t = $Version }
    if ($t -notmatch '^\d+(\.\d+)*$') { return $null }
    $parts = @($t.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    return [int64]($parts[0] * 1000000000L + $parts[1] * 1000000L + $parts[2] * 1000L + $parts[3])
}

function Get-NearestPrimerChangesStub {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceVersion,
        [string]$TargetVersion = '26.2',
        [Parameter(Mandatory)][string]$SearchRoot
    )
    if (-not (Test-Path -LiteralPath $SearchRoot)) { return $null }
    $sourceRank = ConvertTo-VersionRank $SourceVersion
    $exact = Join-Path $SearchRoot ("primer_changes_{0}-to-{1}.md" -f $SourceVersion, $TargetVersion)
    if (Test-Path -LiteralPath $exact) {
        return [pscustomobject]@{ IndexPath = $exact; MatchKind = 'exact'; StubSource = $SourceVersion }
    }
    $best = $null
    $bestRank = $null
    foreach ($file in @(Get-ChildItem -LiteralPath $SearchRoot -Filter ("primer_changes_*-to-{0}.md" -f $TargetVersion) -File -ErrorAction SilentlyContinue)) {
        if ($file.BaseName -notmatch '^primer_changes_(.+)-to-') { continue }
        $stubSource = $Matches[1]
        $rank = ConvertTo-VersionRank $stubSource
        if ($null -eq $sourceRank -or $null -eq $rank) { continue }
        if ($rank -gt $sourceRank) { continue } # never pick a newer source stub
        if ($null -eq $bestRank -or $rank -gt $bestRank) {
            $bestRank = $rank
            $best = [pscustomobject]@{ IndexPath = $file.FullName; MatchKind = 'nearest-older'; StubSource = $stubSource }
        }
    }
    return $best
}

function Resolve-PrimerChangesLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceVersion,
        [string]$TargetVersion = '26.2',
        [string]$StationKnowledgeRoot = (Get-StationKnowledgeRoot)
    )
    $stationBase = $null
    if ($StationKnowledgeRoot) {
        $stationBase = Join-Path $StationKnowledgeRoot ("NeoForge_Primers\{0}" -f $TargetVersion)
    }
    $bundledRoot = Get-BundledPrimerChangesRoot

    $pick = $null
    $ledgerSource = 'missing'
    if ($stationBase -and (Test-Path -LiteralPath $stationBase)) {
        $pick = Get-NearestPrimerChangesStub -SourceVersion $SourceVersion -TargetVersion $TargetVersion -SearchRoot $stationBase
        if ($pick) { $ledgerSource = 'station' }
    }
    if (-not $pick) {
        $pick = Get-NearestPrimerChangesStub -SourceVersion $SourceVersion -TargetVersion $TargetVersion -SearchRoot $bundledRoot
        if ($pick) { $ledgerSource = 'bundled' }
    }

    $indexPath = if ($pick) { [string]$pick.IndexPath } else { $null }
    $shardDir = $null
    $primerChain = @()
    if ($indexPath) {
        $candidateShards = [IO.Path]::Combine([IO.Path]::GetDirectoryName($indexPath), [IO.Path]::GetFileNameWithoutExtension($indexPath))
        if (Test-Path -LiteralPath $candidateShards) { $shardDir = $candidateShards }
        $indexText = Get-Content -LiteralPath $indexPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue
        $chainLine = @($indexText -split "`r?`n" | Where-Object { $_ -match '^- Chain:' } | Select-Object -First 1)
        if ($chainLine) {
            $chainBody = [string]$chainLine
            $chainBody = $chainBody -replace '^- Chain:\s*', ''
            $chainBody = $chainBody.Trim().Trim([char]0x60) # strip surrounding backticks
            # Prefer extracting version tokens so UTF-8 arrows / mojibake cannot break the split.
            $primerChain = @(
                [regex]::Matches($chainBody, '\b(?:1\.\d+(?:\.\d+)?|2[0-9](?:\.\d+)?)\b') |
                    ForEach-Object { $_.Value } |
                    Select-Object -Unique
            )
            if ($primerChain.Count -eq 0) {
                $arrow = [string][char]0x2192
                $chainBody = $chainBody.Replace($arrow, '|').Replace('->', '|')
                $primerChain = @(
                    $chainBody.Split('|') |
                        ForEach-Object { $_.Trim().Trim([char]0x60) } |
                        Where-Object { $_ }
                )
            }
        }
    }

    $matchKind = 'none'
    $stubSourceValue = $null
    if ($pick) {
        $matchKind = [string]$pick.MatchKind
        $stubSourceValue = $pick.StubSource
    }
    return [pscustomobject]@{
        IndexPath     = $indexPath
        ShardDir      = $shardDir
        LedgerSource  = $ledgerSource
        MatchKind     = $matchKind
        StubSource    = $stubSourceValue
        PrimerChain   = $primerChain
        TargetVersion = $TargetVersion
        SourceVersion = $SourceVersion
    }
}

function Get-DetectedHardDepSignals {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [object[]]$DependencyRecords = @()
    )
    $features = @($Profile.ApiFeatures) | ForEach-Object { [string]$_ }
    $framework = [string]$Profile.Framework
    $geckolib = $false
    $mcreator = $false
    if ($features -contains 'legacy-geckolib' -or $features -contains 'geckolib') { $geckolib = $true }
    if ($features -contains 'mcreator-source' -or $framework -eq 'mcreator') { $mcreator = $true }
    foreach ($rec in @($DependencyRecords)) {
        $id = [string]$rec.ModId
        if ($id -match '^(geckolib|geckolib3|geckolib4)$') { $geckolib = $true }
    }
    # RecommendedPasses can also signal intent
    foreach ($pass in @($Profile.RecommendedPasses)) {
        if ($pass -eq 'geckolib') { $geckolib = $true }
        if ($pass -like 'mcreator-*') { $mcreator = $true }
    }
    return [pscustomobject]@{
        GeckoLib = [bool]$geckolib
        MCreator = [bool]$mcreator
    }
}

function Resolve-DependencyChangeLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('geckolib', 'mcreator')][string]$Track,
        [string]$SourceVersion = ''
    )
    $root = Get-BundledDepChangesRoot
    $trackRoot = Join-Path $root $Track
    if (-not (Test-Path -LiteralPath $trackRoot)) {
        return [pscustomobject]@{ Track = $Track; LedgerSource = 'missing'; IndexPath = $null; Files = @(); Band = $null }
    }
    $indexPath = Join-Path $trackRoot 'index.md'
    $files = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $indexPath) { $files.Add($indexPath) | Out-Null }
    $band = $null
    if ($Track -eq 'geckolib') {
        $ledger = Join-Path $trackRoot 'geckolib-4-to-5.md'
        if (Test-Path -LiteralPath $ledger) { $files.Add($ledger) | Out-Null }
        $band = '4-to-5.5.3'
    }
    elseif ($Track -eq 'mcreator') {
        $rank = ConvertTo-VersionRank $SourceVersion
        $band1201 = ConvertTo-VersionRank '1.20.1'
        $use1201 = ($null -ne $rank -and $null -ne $band1201 -and $rank -le $band1201) -or ($SourceVersion -eq '1.20.1')
        if ($use1201) {
            $band = '1.20.1'
            $ledger = Join-Path $trackRoot 'mcreator-1.20.1-to-26.2.md'
        }
        else {
            $band = '1.21.x'
            $ledger = Join-Path $trackRoot 'mcreator-1.21.x-to-26.2.md'
        }
        if (Test-Path -LiteralPath $ledger) { $files.Add($ledger) | Out-Null }
    }
    return [pscustomobject]@{
        Track        = $Track
        LedgerSource = if ($files.Count -gt 0) { 'bundled' } else { 'missing' }
        IndexPath    = if (Test-Path -LiteralPath $indexPath) { $indexPath } else { $null }
        Files        = @($files)
        Band         = $band
    }
}

function Select-IncrementalDeltaHits {
    [CmdletBinding()]
    param(
        [string[]]$Files = @(),
        [string[]]$Terms = @(),
        [int]$MaxHits = 8
    )
    $hits = @()
    $termList = @()
    foreach ($term in @($Terms)) {
        $termText = [string]$term
        if ($termText.Length -ge 3 -and $termList -notcontains $termText) {
            $termList += $termText
        }
    }
    foreach ($file in @($Files)) {
        $filePath = [string]$file
        if (-not $filePath -or -not (Test-Path -LiteralPath $filePath)) { continue }
        $lines = @(Get-Content -LiteralPath $filePath -ErrorAction SilentlyContinue)
        $lineCount = $lines.Count
        for ($i = 0; $i -lt $lineCount; $i++) {
            $line = [string]$lines[$i]
            $matched = @()
            if ($termList.Count -eq 0) {
                if ($line -match '^\|\s+[a-z0-9-]+\s+\|') {
                    $matched = @('ledger-row')
                }
                else { continue }
            }
            else {
                $lineLower = $line.ToLowerInvariant()
                foreach ($termText in $termList) {
                    if ($lineLower.Contains($termText.ToLowerInvariant())) {
                        $matched += $termText
                    }
                }
                if ($matched.Count -eq 0) { continue }
            }
            $start = 0
            if ($i -gt 0) { $start = $i - 1 }
            $end = $i + 1
            if ($end -ge $lineCount) { $end = $lineCount - 1 }
            $chunk = @()
            for ($k = $start; $k -le $end; $k++) { $chunk += [string]$lines[$k] }
            $excerpt = [string]::Join("`n", $chunk)
            if ($excerpt.Length -gt 500) { $excerpt = $excerpt.Substring(0, 500) }
            $hits += [pscustomobject]@{
                path          = $filePath
                line          = ($i + 1)
                matched_terms = $matched
                excerpt       = $excerpt
            }
            if ($hits.Count -ge $MaxHits) { return $hits }
            break
        }
    }
    return $hits
}

function Get-EvidenceQueryTerms {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile)
    $terms = New-Object System.Collections.Generic.List[string]
    foreach ($feat in @($Profile.ApiFeatures)) {
        $id = [string]$feat
        if ($id) { $terms.Add($id) | Out-Null }
    }
    foreach ($extra in @('GuiGraphics', 'AnimationController', 'RenderSystem', 'PacketDistributor', 'RecordCodecBuilder', 'GeckoLib', 'mcreator')) {
        $terms.Add($extra) | Out-Null
    }
    return @($terms | Select-Object -Unique)
}

function Write-MigrationEvidencePacket {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [object[]]$DependencyRecords = @(),
        [string]$ConverterVersion = '2.0.3'
    )
    $sourceVersion = [string]$Profile.SourceVersion
    $neo = Resolve-PrimerChangesLedger -SourceVersion $sourceVersion -TargetVersion '26.2'
    $signals = Get-DetectedHardDepSignals -Profile $Profile -DependencyRecords $DependencyRecords
    $terms = Get-EvidenceQueryTerms -Profile $Profile
    $exactRules = @(Get-PrimerMigrationRules -SourceVersion $sourceVersion)

    $neoFiles = @()
    if ($neo.IndexPath) { $neoFiles += $neo.IndexPath }
    if ($neo.ShardDir) {
        $neoFiles += @(Get-ChildItem -LiteralPath $neo.ShardDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
            Sort-Object {
                $rank = ConvertTo-VersionRank $_.BaseName
                if ($null -eq $rank) { [int64]0 } else { [int64]$rank }
            } -Descending |
            Select-Object -ExpandProperty FullName)
    }
    $neoHits = @(Select-IncrementalDeltaHits -Files $neoFiles -Terms $terms -MaxHits 8)

    $tracks = [ordered]@{
        neoforge = [ordered]@{
            ledger_source      = $neo.LedgerSource
            match              = $neo.MatchKind
            stub_source        = $neo.StubSource
            primer_chain       = @($neo.PrimerChain)
            index              = $neo.IndexPath
            shards             = $neo.ShardDir
            matched_deltas     = @($neoHits)
            executable_index   = (Join-Path $PSScriptRoot 'PrimerChangeIndex.json')
            exact_primer_rules = @($exactRules)
        }
    }

    if ($signals.GeckoLib) {
        $g = Resolve-DependencyChangeLedger -Track 'geckolib' -SourceVersion $sourceVersion
        $gHits = @(Select-IncrementalDeltaHits -Files $g.Files -Terms $terms -MaxHits 6)
        $tracks.geckolib = [ordered]@{
            required         = $true
            from_api         = '4.x'
            to_api           = '5.5.3'
            band             = $g.Band
            ledger_source    = $g.LedgerSource
            index            = $g.IndexPath
            files            = @($g.Files)
            matched_deltas   = @($gHits)
            executable_pass  = 'geckolib'
        }
    }
    if ($signals.MCreator) {
        $m = Resolve-DependencyChangeLedger -Track 'mcreator' -SourceVersion $sourceVersion
        $mHits = @(Select-IncrementalDeltaHits -Files $m.Files -Terms $terms -MaxHits 8)
        $tracks.mcreator = [ordered]@{
            required           = $true
            band               = $m.Band
            ledger_source      = $m.LedgerSource
            index              = $m.IndexPath
            files              = @($m.Files)
            matched_deltas     = @($mHits)
            executable_passes  = @($Profile.RecommendedPasses | Where-Object { $_ -like 'mcreator-*' })
            upstream_catalog   = 'knowledge/Solved_Problems/legacy-java-converter-26.2/MCreator-generator-delta-catalog.md'
        }
    }

    $claim = 'LEDGER_MISSING'
    if ($neo.LedgerSource -ne 'missing') { $claim = 'LEDGER_ATTACHED' }
    if (($signals.GeckoLib -or $signals.MCreator) -and $neo.LedgerSource -eq 'missing') { $claim = 'PARTIAL' }
    if ($neo.LedgerSource -ne 'missing' -and (($signals.GeckoLib -and -not $tracks.Contains('geckolib')) -or ($signals.MCreator -and -not $tracks.Contains('mcreator')))) {
        $claim = 'PARTIAL'
    }

    $packet = [ordered]@{
        schema                 = 'rb-converter-migration-evidence-v1'
        converter_version      = $ConverterVersion
        source_version         = $sourceVersion
        target_version         = '26.2'
        route                  = [string]$Profile.Route
        primer_selection_rule  = 'source_version < primer_version <= target_version'
        grounding_rule         = 'Incremental post-source deltas only; prefer primer_changes shards over full primers; confirm final NeoForge APIs against exact 26.2 source; dep pins from DependencyCatalog. ExactPrimer/GeckoLib/MCreator passes remain executable.'
        claim_status           = $claim
        hard_dep_signals       = [ordered]@{ geckolib = [bool]$signals.GeckoLib; mcreator = [bool]$signals.MCreator }
        tracks                 = $tracks
    }

    $jsonPath = Join-Path $OutputDirectory 'MIGRATION_EVIDENCE.json'
    $mdPath = Join-Path $OutputDirectory 'MIGRATION_EVIDENCE.md'
    $json = $packet | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($jsonPath, $json + "`r`n")

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add('# Migration evidence packet') | Out-Null
    $md.Add('') | Out-Null
    $md.Add(('Converter **{0}**; source **{1}** -> target **26.2**; route `{2}`; claim `{3}`.' -f $ConverterVersion, $sourceVersion, $Profile.Route, $claim)) | Out-Null
    $md.Add('') | Out-Null
    $md.Add('Deterministic ledgers select incremental post-source deltas. ExactPrimer / GeckoLib / MCreator PowerShell passes remain the executors.') | Out-Null
    $md.Add('') | Out-Null
    $md.Add('## NeoForge primers') | Out-Null
    $md.Add('') | Out-Null
    $md.Add(('- Ledger source: `{0}` (match `{1}`)' -f $neo.LedgerSource, $neo.MatchKind)) | Out-Null
    if ($neo.IndexPath) { $md.Add(('- Index: `{0}`' -f $neo.IndexPath)) | Out-Null }
    if ($neo.ShardDir) { $md.Add(('- Shards: `{0}`' -f $neo.ShardDir)) | Out-Null }
    if (@($neo.PrimerChain).Count -gt 0) { $md.Add(('- Chain: `{0}`' -f ($neo.PrimerChain -join ' -> '))) | Out-Null }
    $ruleText = if ($exactRules.Count) { $exactRules -join ', ' } else { '(none)' }
    $md.Add(('- ExactPrimer rule IDs: `{0}`' -f $ruleText)) | Out-Null
    foreach ($hit in $neoHits) {
        $md.Add(('- Hit L{0} `{1}`: {2}' -f $hit.line, $hit.path, (($hit.matched_terms) -join ', '))) | Out-Null
    }
    if ($tracks.Contains('geckolib')) {
        $g = $tracks.geckolib
        $md.Add('') | Out-Null
        $md.Add('## GeckoLib') | Out-Null
        $md.Add('') | Out-Null
        $md.Add(('- Band: `{0}` -> `{1}` ({2})' -f $g.from_api, $g.to_api, $g.band)) | Out-Null
        $md.Add(('- Ledger: `{0}`' -f $g.ledger_source)) | Out-Null
        if ($g.index) { $md.Add(('- Index: `{0}`' -f $g.index)) | Out-Null }
        $md.Add(('- Executable pass: `{0}`' -f $g.executable_pass)) | Out-Null
    }
    if ($tracks.Contains('mcreator')) {
        $m = $tracks.mcreator
        $md.Add('') | Out-Null
        $md.Add('## MCreator') | Out-Null
        $md.Add('') | Out-Null
        $md.Add(('- Band: `{0}`' -f $m.band)) | Out-Null
        $md.Add(('- Ledger: `{0}`' -f $m.ledger_source)) | Out-Null
        if ($m.index) { $md.Add(('- Index: `{0}`' -f $m.index)) | Out-Null }
        $passText = if (@($m.executable_passes).Count) { @($m.executable_passes) -join ', ' } else { 'mcreator-*' }
        $md.Add(('- Executable passes: `{0}`' -f $passText)) | Out-Null
        $md.Add(('- Upstream catalog: `{0}`' -f $m.upstream_catalog)) | Out-Null
    }
    $md.Add('') | Out-Null
    $md.Add('Machine-readable twin: `MIGRATION_EVIDENCE.json`.') | Out-Null
    [IO.File]::WriteAllText($mdPath, (($md -join "`r`n") + "`r`n"))

    return [pscustomobject]@{
        JsonPath     = $jsonPath
        MarkdownPath = $mdPath
        ClaimStatus  = $claim
        Packet       = $packet
        Signals      = $signals
        NeoForge     = $neo
    }
}

function Add-MigrationEvidenceToProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)]$EvidenceResult
    )
    $Profile | Add-Member -NotePropertyName MigrationEvidence -NotePropertyValue ([pscustomobject]@{
            ClaimStatus     = $EvidenceResult.ClaimStatus
            JsonPath        = $EvidenceResult.JsonPath
            MarkdownPath    = $EvidenceResult.MarkdownPath
            NeoForgeLedger  = $EvidenceResult.NeoForge.LedgerSource
            HardDepSignals  = $EvidenceResult.Signals
        }) -Force
    return $Profile
}

function Write-CompileDiagnosticSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LogPath, [Parameter(Mandatory)][int]$ExitCode)
    if (-not (Test-Path -LiteralPath $LogPath)) { return $null }
    $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
    $errorLines = @($lines | Where-Object { $_ -match '(?i)(?:\.java:\d+:\s+error:|^\s*error:)' })
    $families = [ordered]@{
        'missing-symbol-or-package' = @($lines | Where-Object { $_ -match '(?i)cannot find symbol|package .+ does not exist' }).Count
        'signature-or-type-change' = @($lines | Where-Object { $_ -match '(?i)cannot be applied to given types|incompatible types|does not override' }).Count
        'access-or-removed-api' = @($lines | Where-Object { $_ -match '(?i)has private access|has protected access|cannot be accessed|deprecated and marked for removal' }).Count
        'decompiler-artifact' = @($lines | Where-Object { $_ -match "(?i)illegal start|not a statement|';' expected|reached end of file" }).Count
    }
    $summary = [pscustomobject]@{
        SchemaVersion = 1; ExitCode = $ExitCode; Succeeded = ($ExitCode -eq 0)
        ErrorLineCount = $errorLines.Count; Categories = $families
        NextAction = if ($ExitCode -eq 0) { 'Install the versioned build/libs JAR and runClient-test it.' } else { 'Fix the first error family, rerun gradlew build, and repeat.' }
    }
    $dir = Split-Path $LogPath -Parent
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'COMPILE_REPORT.json') -Encoding UTF8
    $rows = @($families.GetEnumerator() | ForEach-Object { "| $($_.Key) | $($_.Value) |" })
    @(
        '# Compile diagnostic report', '', "- Exit code: $ExitCode", "- Error lines: $($errorLines.Count)",
        "- Result: $(if ($ExitCode -eq 0) { 'compileJava succeeded' } else { 'compileJava needs follow-up' })", '',
        '## Error families', '', '| Family | Matches |', '|---|---:|'
    ) + $rows + @('', 'See `compile-errors.log` for the full Gradle output.') |
        Set-Content -LiteralPath (Join-Path $dir 'COMPILE_REPORT.md') -Encoding UTF8
    return $summary
}

function ConvertFrom-ClassFileMajorToJavaMajor {
    param([Parameter(Mandatory)][int]$ClassMajor)
    if ($ClassMajor -lt 45) { return 0 }
    return ($ClassMajor - 44)
}

function Get-JavaMajorVersion {
    param([Parameter(Mandatory)][string]$JavaPath)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $JavaPath
        $psi.Arguments = '-version'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [Diagnostics.Process]::Start($psi)
        $err = $proc.StandardError.ReadToEnd()
        $out = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        $text = "$err`n$out"
        if ($text -match 'version\s+"1\.(\d+)') { return [int]$Matches[1] }
        if ($text -match 'version\s+"(\d+)') { return [int]$Matches[1] }
    } catch {
        return 0
    }
    return 0
}

function Get-JarRequiredJavaMajor {
    param(
        [Parameter(Mandatory)][string]$JarPath,
        [string]$PreferredEntry = 'org/jetbrains/java/decompiler/main/decompiler/ConsoleDecompiler.class',
        [int]$FallbackJavaMajor = 17
    )
    if (-not (Test-Path -LiteralPath $JarPath)) { return $FallbackJavaMajor }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $JarPath).Path)
        $maxClassMajor = 0
        $preferred = $zip.Entries | Where-Object { $_.FullName -eq $PreferredEntry } | Select-Object -First 1
        $sample = New-Object System.Collections.Generic.List[object]
        if ($preferred) { $sample.Add($preferred) | Out-Null }
        $zip.Entries |
            Where-Object { $_.FullName -like '*.class' -and $_.FullName -ne $PreferredEntry } |
            Select-Object -First 40 |
            ForEach-Object { $sample.Add($_) | Out-Null }
        foreach ($entry in $sample) {
            $stream = $null
            try {
                $stream = $entry.Open()
                $header = New-Object byte[] 8
                $read = $stream.Read($header, 0, 8)
                if ($read -lt 8) { continue }
                if ($header[0] -ne 0xCA -or $header[1] -ne 0xFE -or $header[2] -ne 0xBA -or $header[3] -ne 0xBE) { continue }
                $classMajor = ($header[6] -shl 8) -bor $header[7]
                if ($classMajor -gt $maxClassMajor) { $maxClassMajor = $classMajor }
            } finally {
                if ($stream) { $stream.Dispose() }
            }
        }
        if ($maxClassMajor -le 0) { return $FallbackJavaMajor }
        $javaMajor = ConvertFrom-ClassFileMajorToJavaMajor -ClassMajor $maxClassMajor
        if ($javaMajor -lt 8) { return $FallbackJavaMajor }
        return $javaMajor
    } catch {
        return $FallbackJavaMajor
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Get-DestinationJavaMajorForMinecraft {
    <#
    .SYNOPSIS
      Map a Minecraft / NeoForge target version to the destination JDK major the
      installer must build with. NeoForge 26.2 → Java 25.
    #>
    param(
        [string]$MinecraftVersion = '26.2',
        [int]$FallbackJavaMajor = 25
    )
    if (-not $MinecraftVersion) { return $FallbackJavaMajor }
    switch -Regex ($MinecraftVersion.Trim()) {
        '^26(\.|$)' { return 25 }
        '^1\.21(\.|$)' { return 21 }
        '^1\.20(\.|$)' { return 17 }
        default { return $FallbackJavaMajor }
    }
}

function Get-ProjectRequiredJavaMajor {
    <#
    .SYNOPSIS
      Read a NeoForge/ModDevGradle project's required Java major from build.gradle
      (JavaLanguageVersion.of / options.release) and gradle.properties minecraft_version.
      Fallback 25 for Minecraft 26.2. Installer builds always use this destination major.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [int]$FallbackJavaMajor = 25
    )
    $found = New-Object System.Collections.Generic.List[int]
    $buildGradle = Join-Path $ProjectRoot 'build.gradle'
    if (Test-Path -LiteralPath $buildGradle) {
        $text = Get-Content -LiteralPath $buildGradle -Raw -ErrorAction SilentlyContinue
        if ($text) {
            foreach ($m in [regex]::Matches($text, 'JavaLanguageVersion\.of\(\s*(\d+)\s*\)')) {
                $found.Add([int]$m.Groups[1].Value) | Out-Null
            }
            foreach ($m in [regex]::Matches($text, 'options\.release\s*=\s*(\d+)')) {
                $found.Add([int]$m.Groups[1].Value) | Out-Null
            }
        }
    }
    $propsPath = Join-Path $ProjectRoot 'gradle.properties'
    if (Test-Path -LiteralPath $propsPath) {
        $propsText = Get-Content -LiteralPath $propsPath -Raw -ErrorAction SilentlyContinue
        if ($propsText -and $propsText -match '(?m)^\s*minecraft_version\s*=\s*(\S+)') {
            $found.Add([int](Get-DestinationJavaMajorForMinecraft -MinecraftVersion $Matches[1].Trim() -FallbackJavaMajor $FallbackJavaMajor)) | Out-Null
        }
    }
    if ($found.Count -eq 0) { return $FallbackJavaMajor }
    return (($found | Measure-Object -Maximum).Maximum)
}

function Resolve-Java {
    param(
        [string]$Preferred,
        [int]$MinimumMajor = 17,
        [string]$ForTool = 'tool'
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    # Destination JDK search paths first — never prefer a stale Java-8 JAVA_HOME/PATH hit.
    foreach ($pattern in @(
            "${env:ProgramFiles}\Eclipse Adoptium\jdk-*\bin\java.exe",
            "${env:ProgramFiles}\Microsoft\jdk-*\bin\java.exe",
            "${env:ProgramFiles}\Java\jdk-*\bin\java.exe",
            "${env:ProgramFiles}\Amazon Corretto\jdk*\bin\java.exe",
            "${env:LocalAppData}\Programs\Eclipse Adoptium\jdk-*\bin\java.exe"
        )) {
        Get-Item $pattern -ErrorAction SilentlyContinue | ForEach-Object { $candidates.Add($_.FullName) | Out-Null }
    }
    if ($Preferred) { $candidates.Insert(0, $Preferred) | Out-Null }
    if ($env:JAVA_HOME) { $candidates.Add((Join-Path $env:JAVA_HOME 'bin\java.exe')) | Out-Null }
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { $candidates.Add($cmd.Source) | Out-Null }

    $usable = @()
    $seen = @{}
    foreach ($candidate in @($candidates)) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
        $full = [IO.Path]::GetFullPath($candidate)
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $major = Get-JavaMajorVersion -JavaPath $full
        if ($major -ge $MinimumMajor) {
            $usable += [pscustomobject]@{ Path = $full; Major = $major }
        }
    }
    if ($usable.Count -eq 0) {
        throw ("{0} requires Java {1}+. No matching JDK was found. Install Temurin/Microsoft JDK {1}+ or pass -JavaExe." -f $ForTool, $MinimumMajor)
    }
    # Preferred only wins when it already meets the destination major.
    if ($Preferred -and (Test-Path -LiteralPath $Preferred)) {
        $prefFull = [IO.Path]::GetFullPath($Preferred)
        $prefHit = $usable | Where-Object { $_.Path -eq $prefFull } | Select-Object -First 1
        if ($prefHit) { return $prefHit }
    }
    # Always prefer the exact destination major (e.g. 25 for NeoForge 26.2).
    $exact = @($usable | Where-Object { $_.Major -eq $MinimumMajor } | Select-Object -First 1)
    if ($exact.Count -gt 0) { return $exact[0] }
    # Otherwise closest higher installed JDK — never a lower ambient JAVA_HOME.
    return ($usable | Sort-Object Major | Select-Object -First 1)
}

function Get-JavaHomeFromJavaExe {
    param([Parameter(Mandatory)][string]$JavaExePath)
    $bin = Split-Path -Parent $JavaExePath
    return (Split-Path -Parent $bin)
}

function Set-ProjectDestinationJavaHome {
    <#
    .SYNOPSIS
      Pin a converted project's Gradle JVM to the destination JDK major by writing
      org.gradle.java.home into gradle.properties. Installer -Compile and later
      bare gradlew builds then ignore a Java-8 JAVA_HOME/PATH.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [int]$FallbackJavaMajor = 25,
        [int]$RequiredMajor = 0,
        [switch]$ThrowIfMissing
    )
    if ($RequiredMajor -le 0) {
        $RequiredMajor = Get-ProjectRequiredJavaMajor -ProjectRoot $ProjectRoot -FallbackJavaMajor $FallbackJavaMajor
    }
    if ($RequiredMajor -lt 17) { $RequiredMajor = 17 }

    try {
        $choice = Resolve-Java -MinimumMajor $RequiredMajor -ForTool ("destination Java {0}" -f $RequiredMajor)
    } catch {
        if ($ThrowIfMissing) { throw }
        return $null
    }

    $javaHome = Get-JavaHomeFromJavaExe -JavaExePath $choice.Path
    $propsPath = Join-Path $ProjectRoot 'gradle.properties'
    $homeProp = ($javaHome -replace '\\', '/')
    $line = "org.gradle.java.home=$homeProp"
    if (Test-Path -LiteralPath $propsPath) {
        $text = Get-Content -LiteralPath $propsPath -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { $text = '' }
        if ($text -match '(?m)^\s*org\.gradle\.java\.home\s*=') {
            $text = [regex]::Replace($text, '(?m)^\s*org\.gradle\.java\.home\s*=.*$', $line)
        } else {
            if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" }
            $text += "$line`r`n"
        }
        [IO.File]::WriteAllText($propsPath, $text)
    } else {
        [IO.File]::WriteAllText($propsPath, "# Destination JDK pin (NeoForge toolchain)`r`n$line`r`n")
    }

    return [pscustomobject]@{
        RequiredMajor = $RequiredMajor
        SelectedMajor = $choice.Major
        JavaHome      = $javaHome
        JavaExe       = $choice.Path
        PropsPath     = $propsPath
    }
}

function Invoke-GradleBuildWithRequiredJava {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$Tasks = 'build --no-daemon --stacktrace',
        [string]$LogFileName = 'compile-errors.log',
        [int]$FallbackJavaMajor = 25
    )
    $required = Get-ProjectRequiredJavaMajor -ProjectRoot $ProjectRoot -FallbackJavaMajor $FallbackJavaMajor
    # Installer always builds with the destination JDK (25 for NeoForge 26.2), not ambient JAVA_HOME.
    if ($required -lt 17) { $required = 17 }
    $pin = Set-ProjectDestinationJavaHome -ProjectRoot $ProjectRoot -FallbackJavaMajor $FallbackJavaMajor -RequiredMajor $required -ThrowIfMissing
    $javaHome = $pin.JavaHome
    $choiceMajor = $pin.SelectedMajor
    $javaExe = $pin.JavaExe
    $logPath = Join-Path $ProjectRoot $LogFileName
    $gradlew = Join-Path $ProjectRoot 'gradlew.bat'
    if (-not (Test-Path -LiteralPath $gradlew)) { throw "gradlew.bat missing under $ProjectRoot" }

    $oldHome = $env:JAVA_HOME
    $oldPath = $env:PATH
    try {
        $env:JAVA_HOME = $javaHome
        $env:PATH = "$javaHome\bin;$oldPath"
        Push-Location $ProjectRoot
        try {
            cmd /c "gradlew.bat $Tasks > `"$LogFileName`" 2>&1"
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
    } finally {
        $env:JAVA_HOME = $oldHome
        $env:PATH = $oldPath
    }
    return [pscustomobject]@{
        ExitCode       = $exitCode
        RequiredMajor  = $required
        SelectedMajor  = $choiceMajor
        JavaHome       = $javaHome
        JavaExe        = $javaExe
        LogPath        = $logPath
    }
}

function Get-CodexRepairRequestBody {
    <#
    .SYNOPSIS
      Canonical Codex-native request for repairing a failed conversion output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FailedOutput,
        [int]$DestinationJavaMajor = 25,
        [string]$TargetMinecraft = '26.2'
    )
    $failed = $FailedOutput.TrimEnd('\', '/')
    return @"
# LegacyJavaConverter vNext repair request

Codex is the repair orchestrator for this failed LegacyJavaConverter -> NeoForge $TargetMinecraft run.
KAT and Qwen are optional bounded local workers. Codex reviews and verifies every worker result.

FAILED OUTPUT FOLDER:
$failed

NATIVE CODEX WORKSPACE:
- Read ``AGENTS.md`` before editing.
- Invoke ``legacy-java-converter-vnext`` from ``.agents/skills``.
- Use ``repair-failed-262-output`` for this failed output and ``validate-destination-build`` for builds.
- Use the local ``minecraft-knowledge`` MCP declared in ``.codex/config.toml``.
- The active AI and knowledge root is ``C:\GokuCodexAI``.

MANDATORY ORDER — deterministic and known-solution stages precede fresh reasoning:
1. Read ``SOURCE_PROFILE.json``, ``MIGRATION_EVIDENCE.md``, ``conversion-manifest.json``, and ``compile-errors.log`` when present.
2. Confirm the source Minecraft version, loader/framework, mappings, dependencies, target, and recommended passes.
3. Complete deterministic conversion stages and consult the persistent Solutions Index, 262r, solved cases, and matching NeoForge 26.2 primer ledger.
4. Confirm uncertain APIs against exact $TargetMinecraft physical sources and explicit mapping namespaces.
5. Use the JavaParser AST worker for structural Java edits; use lexical transforms only for proven idempotent replacements.
6. Audit assets, models, items, entities, AI, and behaviour against the source inventory.
7. Build with the destination JDK, then report launch, registry/data, content, and runtime behaviour separately.
8. Delegate only one bounded, evidence-backed issue at a time to an optional local worker, then review its result.
9. Encode every durable repair into converter logic or an AST recipe, the Solutions Index/262r, and a regression fixture.

EVIDENCE PACKET:
- Create or refresh ``$failed\EVIDENCE_PACKET.md`` from ``.agents/skills/repair-failed-262-output/references/evidence-packet-template.md``.
- Keep excerpts bounded and point to exact evidence paths instead of copying complete logs.
- Record the deterministic passes and Solutions Index entries already tried.
- Keep the target pinned to NeoForge $TargetMinecraft; do not retarget this conversion to 26.3.

KNOWLEDGE ORDER:
1. Solutions Index and ``C:\GokuCodexAI\Data\262r``.
2. Solved LegacyJavaConverter 26.2 cases.
3. Matching source-to-26.2 primer ledger and dependency delta.
4. Exact NeoForge/Minecraft $TargetMinecraft physical sources and mappings.
5. Fresh reasoning only for evidence-backed gaps.

DESTINATION JAVA / GRADLE:
- Destination JDK major: $DestinationJavaMajor.
- Before the first Gradle command, run:
  ``powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-WithDestinationJava.ps1 -ProjectRoot "$failed"``
- Use the project Gradle wrapper and produce ``build/libs/*.jar``; ``compileJava`` alone is not success.
- Treat an ambient-Java mismatch as an environment error, not a mod source error.

COMPLETION REPORT:
- deterministic conversion stages completed;
- known-solution and AST changes applied;
- preservation status for assets/data/models/items/entities/AI/behaviour;
- clean Gradle build and produced jar;
- runtime launch, registry/data loading, content, and behavioural validation status;
- remaining manual work;
- reusable fixes written back to tests and the Solutions Index.

Never describe a clean build alone as a successful conversion.
Start with the ``legacy-java-converter-vnext`` skill and state the detected source identity and matching 26.2 evidence before editing.
"@
}

function Write-CodexRepairRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FailedOutput,
        [int]$DestinationJavaMajor = 25,
        [string]$TargetMinecraft = '26.2'
    )
    if (-not (Test-Path -LiteralPath $FailedOutput)) {
        throw "Failed output missing: $FailedOutput"
    }
    $null = Set-ProjectDestinationJavaHome -ProjectRoot $FailedOutput -FallbackJavaMajor $DestinationJavaMajor -RequiredMajor $DestinationJavaMajor
    $body = Get-CodexRepairRequestBody -FailedOutput $FailedOutput -DestinationJavaMajor $DestinationJavaMajor -TargetMinecraft $TargetMinecraft
    $path = Join-Path $FailedOutput 'CODEX_REPAIR_REQUEST.md'
    [IO.File]::WriteAllText($path, $body.TrimEnd() + "`r`n", [Text.UTF8Encoding]::new($false))
    return $path
}

function Get-GrokRepairPromptBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FailedOutput,
        [int]$DestinationJavaMajor = 25,
        [string]$TargetMinecraft = '26.2'
    )
    Write-Warning 'Get-GrokRepairPromptBody is deprecated; using Get-CodexRepairRequestBody.'
    return Get-CodexRepairRequestBody @PSBoundParameters
}

function Write-GrokRepairPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FailedOutput,
        [int]$DestinationJavaMajor = 25,
        [string]$TargetMinecraft = '26.2'
    )
    Write-Warning 'Write-GrokRepairPrompt is deprecated; using Write-CodexRepairRequest.'
    return Write-CodexRepairRequest @PSBoundParameters
}

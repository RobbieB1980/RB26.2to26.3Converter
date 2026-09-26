Set-StrictMode -Version Latest

function Set-JsonProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value)
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Remove-JsonProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -ne $Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties.Remove($Name) }
}

function Read-JsonFile([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }

function Get-RB262To263OutputPath([string]$InputPath) {
    $full = [IO.Path]::GetFullPath($InputPath)
    if (Test-Path -LiteralPath $full -PathType Leaf) { $name = [IO.Path]::GetFileNameWithoutExtension($full); $parent = Split-Path -Parent $full }
    else { $name = Split-Path -Leaf $full.TrimEnd('\\','/'); $parent = Split-Path -Parent $full }
    $candidate = Join-Path $parent ("RB-{0}-26.3" -f $name)
    $i = 2
    while (Test-Path -LiteralPath $candidate) { $candidate = Join-Path $parent ("RB-{0}-26.3-{1}" -f $name, $i); $i++ }
    return $candidate
}

function Write-JsonFile([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Update-TextVersionMarkers([string]$Path, [string]$NeoVersion) {
    $text = Get-Content -LiteralPath $Path -Raw
    $normalizedNeoVersion = $NeoVersion -replace '^neoforge-', ''
    $updated = [regex]::Replace($text, '(?im)(minecraft[_\.-]version\s*[=:]\s*["'']?)26\.2(["'']?)', { param($m) $m.Groups[1].Value + '26.3' + $m.Groups[2].Value })
    $updated = [regex]::Replace($updated, '(?im)(neo[_\.-]version\s*[=:]\s*["'']?)26\.2(?:\.\d+)*(?:-[^"''\s]+)?(["'']?)', { param($m) $m.Groups[1].Value + $normalizedNeoVersion + $m.Groups[2].Value })
    $updated = [regex]::Replace($updated, '(?im)(minecraft_version_range\s*[=:]\s*["'']?)\[26\.2\](["'']?)', { param($m) $m.Groups[1].Value + '[26.3]' + $m.Groups[2].Value })
    $updated = [regex]::Replace($updated, '(?im)(versionRange\s*=\s*["''])\[26\.2[^\)]*\)', { param($m) $m.Groups[1].Value + '[' + $normalizedNeoVersion + ',)' })
    $updated = [regex]::Replace($updated, '(?im)(versionRange\s*=\s*["''])\[26\.2\](["''])', { param($m) $m.Groups[1].Value + '[26.3]' + $m.Groups[2].Value })
    if ($updated -ne $text) { Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8; return $true }
    return $false
}

function Convert-NoiseSettings($Json, [System.Collections.Generic.List[string]]$Warnings) {
    if ($null -ne $Json.PSObject.Properties['surface_rule']) {
        Set-JsonProperty $Json 'material_rule' $Json.surface_rule
        Remove-JsonProperty $Json 'surface_rule'
    }
    if ($null -ne $Json.PSObject.Properties['preliminary_surface_level']) {
        Set-JsonProperty $Json 'chunk_surface_level' $Json.preliminary_surface_level
        Remove-JsonProperty $Json 'preliminary_surface_level'
    }
    $router = $Json.noise_router
    if ($null -eq $router) { return }
    $moved = @('barrier','fluid_level_floodedness','fluid_level_spread','lava')
    $aquifers = $null
    foreach ($name in $moved) {
        if ($null -ne $router.PSObject.Properties[$name]) {
            if ($null -eq $aquifers) { $aquifers = [pscustomobject]@{} }
            Set-JsonProperty $aquifers $name $router.$name
            Remove-JsonProperty $router $name
        }
    }
    if ($null -ne $aquifers) { Set-JsonProperty $Json 'aquifers' $aquifers }
    foreach ($name in @('ore_veins_enabled','vein_toggle','vein_ridged','vein_gap','size_horizontal','size_vertical')) {
        if ($null -ne $Json.PSObject.Properties[$name] -or $null -ne $router.PSObject.Properties[$name]) {
            $Warnings.Add("Manual worldgen review required for $name")
        }
    }
}

function Disable-NeoFormRecompilation([string]$Root) {
    $build = Join-Path $Root 'build.gradle'
    if (-not (Test-Path -LiteralPath $build)) { return $false }
    $text = Get-Content -LiteralPath $build -Raw
    $updated = [regex]::Replace($text, '(?m)(^\s*neoForge\s*\{\s*\r?\n)\s*version\s*=\s*project\.neo_version', { param($m) $m.Groups[1].Value + "    enable {`r`n        version = project.neo_version`r`n        disableRecompilation = true`r`n    }" })
    if ($updated -eq $text) { return $false }
    Set-Content -LiteralPath $build -Value $updated -Encoding UTF8
    return $true
}

function Normalize-JavaSources([string]$Root) {
    $count = 0
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            [IO.File]::WriteAllBytes($file.FullName, $bytes[3..($bytes.Length - 1)])
            $count++
            continue
        }
        $text = [IO.File]::ReadAllText($file.FullName)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            [IO.File]::WriteAllText($file.FullName, $text.TrimStart([char]0xFEFF), [Text.UTF8Encoding]::new($false))
            $count++
        }
    }
    return $count
}

function Normalize-TextBoms([string]$Root) {
    $count = 0
    $extensions = @('.gradle','.gradle.kts','.properties','.toml','.json','.md','.txt')
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue) {
        if ($extensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            [IO.File]::WriteAllBytes($file.FullName, $bytes[3..($bytes.Length - 1)])
            $count++
            continue
        }
        $text = [IO.File]::ReadAllText($file.FullName)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            [IO.File]::WriteAllText($file.FullName, $text.TrimStart([char]0xFEFF), [Text.UTF8Encoding]::new($false))
            $count++
        }
    }
    return $count
}

function Update-Java26x3Apis([string]$Root) {
    $count = 0
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $updated = $text
        $updated = [regex]::Replace($updated, 'player\.swing\(InteractionHand\.MAIN_HAND\);', 'player.swing(InteractionHand.MAIN_HAND, net.minecraft.world.item.component.SwingAnimation.DEFAULT, true);')
        $updated = [regex]::Replace($updated, 'clearOrCountMatchingItems\(itemPredicate, maxCount, serverplayer\.inventoryMenu\.getCraftSlots\(\)\)', 'clearOrCountMatchingItems(itemPredicate, false, maxCount, serverplayer.inventoryMenu.getCraftSlots())')
        $updated = [regex]::Replace($updated, 'HashMap var12 = new HashMap\(\);', 'Map<String, Integer> var12 = new HashMap<>();')
        $updated = [regex]::Replace($updated, 'to\.setValue\(sharedProperty\.targetProperty\(\), value\)', 'to.setValue((net.minecraft.world.level.block.state.properties.Property)sharedProperty.targetProperty(), value)')
        if ($updated -match 'Util\.getPlatform\(\)\.openUri\(([^;]+)\);') {
            if ($updated -notmatch 'import java\.awt\.Desktop;') {
                $updated = $updated -replace '(?m)^import net\.minecraft\.util\.Util;\r?$', "import net.minecraft.util.Util;`r`nimport java.awt.Desktop;`r`nimport java.net.URI;"
            }
            $updated = [regex]::Replace($updated, 'Util\.getPlatform\(\)\.openUri\(([^;]+)\);', 'if (Desktop.isDesktopSupported()) { try { Desktop.getDesktop().browse(URI.create($1)); } catch (java.io.IOException ignored) { } }')
        }
        if ($updated -ne $text) {
            [IO.File]::WriteAllText($file.FullName, $updated, [Text.UTF8Encoding]::new($false))
            $count++
        }
    }
    return $count
}

function Invoke-RB262To263 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [string]$OutputPath = '',
        [string]$NeoVersion = 'neoforge-26.3.0.7-beta'
    )
    $resolvedInput = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).Path
    $temporaryInput = $null
    if (Test-Path -LiteralPath $resolvedInput -PathType Leaf) {
        if ([IO.Path]::GetExtension($resolvedInput) -ne '.jar') { throw 'Input file must be a .jar, or provide a project folder.' }
        $legacyRoot = Join-Path ([IO.Path]::GetTempPath()) ('rb262263-legacy-' + [guid]::NewGuid().ToString('N'))
        $decompiled = Join-Path $legacyRoot 'decompiled'
        New-Item -ItemType Directory -Path $legacyRoot -Force | Out-Null
        $legacyScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'legacy-pipeline\Convert-JarToProject.ps1'
        if (-not (Test-Path -LiteralPath $legacyScript)) { throw "Missing legacy JAR pipeline: $legacyScript" }
        & $legacyScript -JarPath $resolvedInput -OutputPath $decompiled -ContinueToNeoForge262 -NeoVersion '26.2.0.72' -MinecraftVersion '26.2' | Out-Null
        $inputFull = $decompiled + '-26.2'
        if (-not (Test-Path -LiteralPath $inputFull -PathType Container)) { throw "Legacy JAR pipeline did not produce a 26.2 scaffold: $inputFull" }
        $temporaryInput = $legacyRoot
    } else { $inputFull = $resolvedInput }
    $targetRoot = Split-Path -Parent $PSScriptRoot
    $knowledgePath = Join-Path $targetRoot 'knowledge\PrimerChangeIndex-26.2-to-26.3.json'
    if (-not (Test-Path -LiteralPath $knowledgePath -PathType Leaf)) { throw "Missing 26.2 -> 26.3 knowledge index: $knowledgePath" }
    $knowledge = Read-JsonFile $knowledgePath
    if ($knowledge.entries.Count -lt 12) { throw '26.2 -> 26.3 knowledge index is incomplete.' }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { $outputFull = Get-RB262To263OutputPath $resolvedInput }
    elseif (-not (Test-Path -LiteralPath $OutputPath)) { $outputFull = [IO.Path]::GetFullPath($OutputPath) } else { $outputFull = (Resolve-Path -LiteralPath $OutputPath).Path }
    if ($resolvedInput.TrimEnd('\') -eq $outputFull.TrimEnd('\')) { throw 'Input and output paths must be different.' }
    $props = Get-ChildItem -LiteralPath $inputFull -Recurse -File -Include '*.properties','*.gradle','*.gradle.kts','mods.toml','*.toml' -ErrorAction SilentlyContinue
    $sourceText = ($props | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    $has262Marker = $sourceText -match '(?<!\d)26\.2(?:\.\d+)?(?!\d)'
    if (-not $has262Marker -and $temporaryInput) {
        $has262Marker = $sourceText -match '(?i)versionRange\s*=\s*["'']\[26\.2|modId\s*=\s*["'']neoforge["'']'
    }
    if (-not $has262Marker) { if ($temporaryInput) { Remove-Item -LiteralPath $temporaryInput -Recurse -Force -ErrorAction SilentlyContinue }; return [pscustomobject]@{ Status='Rejected'; Reason='Input does not contain an exact NeoForge/Minecraft 26.2 marker.' } }
    if ([string]::IsNullOrWhiteSpace($NeoVersion)) { throw 'NeoVersion is required until an official stable NeoForge 26.3 pin is available.' }
    New-Item -ItemType Directory -Path $outputFull -Force | Out-Null
    Get-ChildItem -LiteralPath $inputFull -Force | Copy-Item -Destination $outputFull -Recurse -Force
    $warnings = [System.Collections.Generic.List[string]]::new()
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $outputFull -Recurse -File -Include '*.properties','*.gradle','*.gradle.kts','mods.toml','*.toml') {
        if (Update-TextVersionMarkers $file.FullName $NeoVersion) { $changed.Add($file.FullName.Substring($outputFull.Length + 1)) }
    }
    if (Disable-NeoFormRecompilation $outputFull) { $changed.Add('build.gradle (disable NeoForm recompilation)') }
    $bomCount = Normalize-JavaSources $outputFull
    if ($bomCount -gt 0) { $changed.Add("Java source BOM normalization ($bomCount files)") }
    $textBomCount = Normalize-TextBoms $outputFull
    if ($textBomCount -gt 0) { $changed.Add("Text source BOM normalization ($textBomCount files)") }
    $apiCount = Update-Java26x3Apis $outputFull
    if ($apiCount -gt 0) { $changed.Add("Java 26.3 API compatibility transforms ($apiCount files)") }
    foreach ($file in Get-ChildItem -LiteralPath $outputFull -Recurse -File -Filter 'pack.mcmeta') {
        $json = Read-JsonFile $file.FullName
        $hasData = Test-Path -LiteralPath (Join-Path (Split-Path $file.FullName) 'data')
        Set-JsonProperty $json.pack 'pack_format' $(if ($hasData) { 121.0 } else { 97.1 })
        Write-JsonFile $file.FullName $json
        $changed.Add($file.FullName.Substring($outputFull.Length + 1))
    }
    foreach ($file in Get-ChildItem -LiteralPath $outputFull -Recurse -File -Filter '*.json') {
        if ($file.FullName -notmatch '\\worldgen\\noise_settings\\') { continue }
        $json = Read-JsonFile $file.FullName
        Convert-NoiseSettings $json $warnings
        Write-JsonFile $file.FullName $json
        $changed.Add($file.FullName.Substring($outputFull.Length + 1))
    }
    $manifest = [ordered]@{ target_id='rb-26.2-to-26.3'; status='Converted'; source_path=$resolvedInput; input_kind=$(if ($temporaryInput) { 'jar' } else { 'project-folder' }); output_path=$outputFull; source_minecraft='26.2'; target_minecraft='26.3'; target_neo_version=$NeoVersion; knowledge_index='PrimerChangeIndex-26.2-to-26.3.json'; knowledge_entries=$knowledge.entries.Count; changed_files=@($changed); warnings=@($warnings); validation=[ordered]@{ deterministic_changes=$true; build='not-run'; runtime='not-run'; content='not-run' } }
    Write-JsonFile (Join-Path $outputFull 'conversion-manifest.json') $manifest
    $evidence = @('# RB 26.2 -> 26.3 migration evidence','',"Target NeoForge version: $NeoVersion",'', '## Changed files') + @($changed | ForEach-Object { '- ' + $_ }) + @('', '## Remaining review') + @($warnings | ForEach-Object { '- ' + $_ }) + @('- Client/rendering Java APIs require AST or Codex repair review.', '- Dependency compatibility and Gradle build remain unvalidated until the target NeoForge artifact is available.')
    Set-Content -LiteralPath (Join-Path $outputFull 'MIGRATION_EVIDENCE.md') -Value $evidence -Encoding UTF8
    if ($temporaryInput) { Remove-Item -LiteralPath $temporaryInput -Recurse -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]$manifest
}

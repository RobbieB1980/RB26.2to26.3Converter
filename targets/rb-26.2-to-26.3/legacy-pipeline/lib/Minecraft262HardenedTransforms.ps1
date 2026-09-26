function Convert-Minecraft262LeafApiText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $t = $Text.TrimEnd()
    $nl = if ($t.Contains("`r`n")) { "`r`n" } else { "`n" }

    $t = $t -replace 'getGameRules\(\)\.getInt\(', 'getGameRules().get('
    $t = $t -replace 'getGameRules\(\)\.getBoolean\(', 'getGameRules().get('
    $t = [regex]::Replace($t, '\b(\w+)\.dayTime\(\)', '($1 instanceof net.minecraft.world.level.Level __lvlClock ? __lvlClock.getOverworldClockTime() : 0L)')
    $t = $t -replace '\.getDayTime\(\)', '.getOverworldClockTime()'
    $t = $t -replace 'entityToSpawn\.moveTo\(Vec3\.atBottomCenterOf', 'entityToSpawn.snapTo(Vec3.atBottomCenterOf'
    $t = $t -replace 'new KeyMapping\("([^"]+)",\s*(\d+),\s*"key\.categories\.misc"\)', 'new KeyMapping("$1", $2, KeyMapping.Category.MISC)'
    $t = $t -replace 'import net\.minecraft\.client\.model\.CowModel;', 'import net.minecraft.client.model.animal.cow.CowModel;'
    $t = $t -replace 'import net\.minecraft\.client\.model\.PigModel;', 'import net.minecraft.client.model.animal.pig.PigModel;'
    $t = $t -replace 'MobRenderer<([^,>]+),\s*net\.minecraft\.client\.renderer\.entity\.state\.LivingEntityRenderState,\s*LivingEntityRenderState,\s*([^>]+)>', 'MobRenderer<$1, LivingEntityRenderState, $2>'
    $t = $t -replace 'REGISTRY\.registerBlock\(name, supplier, Properties\.of\(\)\)', 'REGISTRY.registerBlock(name, supplier, () -> Properties.of())'
    $t = $t -replace 'new ArrayList\(world\.players\(\)\)', 'new ArrayList<>(world.players())'
    $t = $t -replace 'guiGraphics\.extractTooltip\(', 'guiGraphics.setTooltipForNextFrame('
    $t = $t -replace 'super\.render\(guiGraphics, mouseX, mouseY, partialTicks\)', 'super.extractRenderState(guiGraphics, mouseX, mouseY, partialTicks)'

    if ($t -match 'extends\s+PickaxeItem' -and $t -match 'TOOL_MATERIAL') {
        $t = $t -replace 'import net\.minecraft\.world\.item\.PickaxeItem;', 'import net.minecraft.world.item.Item;'
        $t = $t -replace 'extends PickaxeItem', 'extends Item'
        $t = [regex]::Replace($t,
            'super\(\s*([A-Z_][A-Z0-9_]*)\s*,\s*([^,]+),\s*([^,]+),\s*(\w+)\s*\)',
            'super($4.pickaxe($1, $2, $3))')
    }

    if ($t -match 'RenderTypes\.eyes' -and $t -notmatch 'import\s+net\.minecraft\.client\.renderer\.rendertype\.RenderTypes') {
        $t = [regex]::Replace($t, '(?m)^(package\s+[^;]+;)', ('$1' + $nl + 'import net.minecraft.client.renderer.rendertype.RenderTypes;'), 1)
    }

    $t = [regex]::Replace($t,
        'computeIfAbsent\(\s*new\s+(?:SavedData\.)?Factory\([^)]+\)\s*,\s*"[^"]+"\s*\)',
        'computeIfAbsent(TYPE)')
    $t = $t -replace '(?m)^import\s+net\.minecraft\.world\.level\.saveddata\.SavedData\.Factory\s*;\r?\n', ''
    return $t
}

function Convert-Minecraft262TreeConfiguredFeatureDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$JsonText)

    $document = $JsonText | ConvertFrom-Json
    if ($document.type -ne 'minecraft:tree' -or $null -eq $document.config) { return $JsonText.TrimEnd() }
    if ($document.config.PSObject.Properties['below_trunk_provider']) { return $JsonText.TrimEnd() }
    $dirt = $document.config.PSObject.Properties['dirt_provider']
    if ($null -eq $dirt) { return $JsonText.TrimEnd() }

    $state = $dirt.Value.state
    if ($null -eq $state) { $state = [ordered]@{ Name = 'minecraft:dirt' } }
    $below = [ordered]@{
        type = 'minecraft:rule_based_state_provider'
        rules = @(
            [ordered]@{
                if_true = [ordered]@{
                    type = 'minecraft:not'
                    predicate = [ordered]@{
                        type = 'minecraft:matching_block_tag'
                        tag = 'minecraft:cannot_replace_below_tree_trunk'
                    }
                }
                then = [ordered]@{
                    type = 'minecraft:simple_state_provider'
                    state = $state
                }
            }
        )
    }

    $document.config.PSObject.Properties.Remove('dirt_provider')
    $document.config.PSObject.Properties.Remove('force_dirt')
    $document.config | Add-Member -NotePropertyName 'below_trunk_provider' -NotePropertyValue $below
    return ($document | ConvertTo-Json -Depth 100)
}

function Convert-Minecraft262ClientItemDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$JsonText,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ModId
    )

    $document = $JsonText | ConvertFrom-Json
    if ($null -eq $document.model -or $document.model.model -ne 'minecraft:item/template_spawn_egg') {
        return $JsonText.TrimEnd()
    }
    $document.model.model = "${ModId}:item/template_spawn_egg"
    return ($document | ConvertTo-Json -Depth 100)
}

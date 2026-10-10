function Update-Known263Data {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $resources = Join-Path $ProjectRoot 'src/main/resources'
    if (-not (Test-Path $resources)) { return }
    # NeoForge's mod pack loader accepts omitted format fields for both pack roles.
    # Only the root mod metadata is affected, never embedded standalone packs.
    $pack = Join-Path $resources 'pack.mcmeta'
    if (Test-Path $pack) {
        $json = Get-Content $pack -Raw | ConvertFrom-Json
        $dirty = $false
        foreach ($name in @('pack_format','min_format','max_format','supported_formats')) {
            if ($null -ne $json.pack.PSObject.Properties[$name]) { $json.pack.PSObject.Properties.Remove($name); $dirty = $true }
        }
        if ($dirty) { [IO.File]::WriteAllText($pack,($json | ConvertTo-Json -Depth 100)); Write-Output 'src/main/resources/pack.mcmeta' }
    }
    foreach ($file in Get-ChildItem $resources -Recurse -File -Filter '*.json') {
        if ($file.FullName -notmatch '\\data\\[^\\]+\\advancement\\') { continue }
        $json = Get-Content $file.FullName -Raw | ConvertFrom-Json
        if ($null -eq $json.PSObject.Properties['criteria']) { continue }
        $dirty = $false
        foreach ($property in $json.criteria.PSObject.Properties) {
            $criterion = $property.Value
            if ($null -eq $criterion.PSObject.Properties['trigger'] -or $criterion.trigger -ne 'minecraft:recipe_unlocked') { continue }
            if ($null -eq $criterion.PSObject.Properties['conditions']) { continue }
            $conditions = $criterion.conditions
            if ($null -ne $conditions.PSObject.Properties['recipe'] -and $null -eq $conditions.PSObject.Properties['recipes'] -and $conditions.recipe -is [string]) {
                $conditions | Add-Member -NotePropertyName 'recipes' -NotePropertyValue $conditions.recipe
                $conditions.PSObject.Properties.Remove('recipe'); $dirty = $true
            }
        }
        if ($dirty) { [IO.File]::WriteAllText($file.FullName,($json | ConvertTo-Json -Depth 100)); Write-Output $file.FullName.Substring($ProjectRoot.TrimEnd('\').Length+1) }
    }
}

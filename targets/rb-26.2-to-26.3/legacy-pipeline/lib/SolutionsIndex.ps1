<# Deterministic executable facade over the persistent solved-conversion catalog. #>
[CmdletBinding()]
param()

function Read-SolutionsIndex {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot 'SolvedConversionIndex.json'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Solutions Index missing: $Path" }
    $index = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $index.solutions) { throw "Solutions Index contains no solutions: $Path" }
    return $index
}

function Find-CodexSolutions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModId,
        [Parameter(Mandatory)][string]$SourceVersion,
        [string]$TargetVersion = '26.2',
        $Index = (Read-SolutionsIndex)
    )
    $mod = $ModId.Trim().ToLowerInvariant()
    $results = foreach ($solution in @($Index.solutions)) {
        $mods = @($solution.modIds | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $versions = @($solution.sourceVersions) + @($solution.sourceVersionAliases)
        if (($mods -contains $mod) -and ($versions -contains $SourceVersion)) {
            [pscustomobject]@{
                id = [string]$solution.id
                targetVersion = $TargetVersion
                match = 'exact'
                forcePasses = @($solution.forcePasses)
                transforms = @($solution.transforms)
                overlays = @($solution.overlays)
                notes = [string]$solution.notes
            }
        }
    }
    @($results | Sort-Object id)
}

function Get-SolutionsIndexEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModId, [Parameter(Mandatory)][string]$SourceVersion, [string]$TargetVersion = '26.2', $Index = (Read-SolutionsIndex))
    $matches = @(Find-CodexSolutions -ModId $ModId -SourceVersion $SourceVersion -TargetVersion $TargetVersion -Index $Index)
    [pscustomobject]@{
        consulted = $true
        indexVersion = $Index.schemaVersion
        modId = $ModId
        sourceVersion = $SourceVersion
        targetVersion = $TargetVersion
        matches = $matches
        nextStage = if ($matches.Count) { 'apply_known_solution' } else { 'exact_version_evidence' }
    }
}

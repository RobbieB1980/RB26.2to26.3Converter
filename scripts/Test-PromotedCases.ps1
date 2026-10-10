param([string]$TargetRoot=(Join-Path $PSScriptRoot '../targets/rb-26.2-to-26.3'))
$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('rb-promoted-cases-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/project","$root/config" -Force | Out-Null
'{"codex_orchestrator":{"primary":{"model":"test","reasoning_effort":"high"},"fallback":{"model":"test","reasoning_effort":"medium"}}}' | Set-Content "$root/config/gokuai.json"
$manifest=@{target_id='rb-26.2-to-26.3';source_minecraft='26.2';target_minecraft='26.3';target_neo_version='neoforge-26.3.0.22-beta'}
$manifest | ConvertTo-Json | Set-Content "$root/project/conversion-manifest.json"
$samples=[ordered]@{
 'renderpearl-sky-263022'='import com.mojang.blaze3d.PrimitiveTopology; error: cannot find symbol'
 'payload-registration-263022'='error: no suitable method found for playBidirectional(Type<CAP#1>,StreamCodec<CAP#2,CAP#3>)'
 'door-piston-reaction-263022'='properties.pushReaction(PushReaction.DESTROY) error: cannot find symbol'
 'mod-pack-metadata-263022'='Pack declared support for versions 107 to 107 but declared main format is 121'
 'recipe-unlocked-263022'='No key recipes in MapLike[{"recipe":"example:axe"}]'
 'component-tools-263022'='import net.minecraft.world.item.AxeItem; error: cannot find symbol'
 'codex-desktop-cli-discovery-263022'='Codex CLI unavailable. Prepared request is retained at C:\example\REPAIR_REQUEST.md'
 'configuration-dependency-263022'='Dependency configuration: blocked No verified project identity in dependency-index.json; refusing name-search guesses'
 'tarkovcraft-core-api-mixins-263022'='error: cannot find symbol DataPackRegistryEvent.NewRegistry'
 'tarkovcraft-core-mixin-signatures-263022'='InvalidInjectionException Invalid descriptor on tarkovcraft_core.mixins.json:LivingEntityMixin CallbackInfoReturnable is required!'
}
foreach($id in $samples.Keys){
 $samples[$id] | Set-Content "$root/project/compile-errors.log"
 & "$TargetRoot/Open-CodexRepairSession.ps1" -FailedOutput "$root/project" -GokuRoot $root -PrepareOnly | Out-Null
 $packet=Get-ChildItem "$root/project/.gokuai/issues" -Directory | Sort-Object CreationTime -Descending | Select-Object -First 1
 $request=Get-Content "$($packet.FullName)/request.json" -Raw | ConvertFrom-Json
 if(@($request.matched_cases).Count -ne 1 -or $request.matched_cases[0].evidence.id -ne $id){throw "Expected one exact match for $id"}
}
$legacyRoot=Join-Path $TargetRoot 'legacy-pipeline'
$index=Get-Content (Join-Path $legacyRoot 'lib/SolvedConversionIndex.json') -Raw | ConvertFrom-Json
if(@($index.solutions | Where-Object {$_.id -eq 'CASE-007-toww-26.2'}).Count){throw 'Target-specific TOWW case leaked into the pre-26.2 solved-conversion index.'}
$legacyCases=@($index.solutions | Where-Object {$_.sourceVersions -contains '26.2'})
foreach($case in $legacyCases){
 if(@($case.forcePasses | Where-Object {$_ -in @('srg-1.20.1','mcreator-1.20.1')}).Count){throw "Pre-26.2 pass attached to a 26.2 source case: $($case.id)"}
}
. (Join-Path $legacyRoot 'lib/ConversionCore.ps1')
$routePasses=@(Get-RecommendedMigrationPasses -Route 'already-26.2')
if(@($routePasses | Where-Object {$_ -in @('srg-1.20.1','mcreator-1.20.1')}).Count){throw 'Already-26.2 route includes a pre-26.2 migration pass.'}
$manifest.target_neo_version='neoforge-26.3.0.7-beta'
$manifest | ConvertTo-Json | Set-Content "$root/project/conversion-manifest.json"
& "$TargetRoot/Open-CodexRepairSession.ps1" -FailedOutput "$root/project" -GokuRoot $root -PrepareOnly | Out-Null
$packet=Get-ChildItem "$root/project/.gokuai/issues" -Directory | Sort-Object CreationTime -Descending | Select-Object -First 1
$request=Get-Content "$($packet.FullName)/request.json" -Raw | ConvertFrom-Json
if(@($request.matched_cases).Count){throw 'New cases leaked into an older target'}
Write-Host "PASS: $($samples.Count) bundled solved-case matches, exact-version exclusion, and no pre-26.2 passes on the already-26.2 route."

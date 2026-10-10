$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$target = Join-Path $repo 'targets/rb-26.2-to-26.3'
$root = Join-Path $env:TEMP ('rb-api-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/src/main/java" -Force | Out-Null
Copy-Item "$repo/tests/fixtures/known-263-apis/*" "$root/src/main/java" -Recurse
New-Item -ItemType Directory -Path "$root/src/main/java/unsupported" -Force | Out-Null
$unsupported = (Get-Content "$root/src/main/java/four-argument-transform/RenderUtils.java" -Raw).Replace('new Vector3f()', 'new Vector3f(1, 2, 3)')
[IO.File]::WriteAllText("$root/src/main/java/unsupported/RenderUtils.java",$unsupported)
$unsupportedHash=(Get-FileHash "$root/src/main/java/unsupported/RenderUtils.java").Hash
@'
// PushReaction.DESTROY must remain in comments and strings.
class Unrelated { String text = "PushReaction.DESTROY"; }
'@ | Set-Content "$root/src/main/java/Unrelated.java"
$unrelated = (Get-FileHash "$root/src/main/java/Unrelated.java").Hash
& "$target/Repair-Known263Apis.ps1" -ProjectRoot $root -NeoVersion '26.3.0.22-beta'
$render = Get-Content "$root/src/main/java/client/RenderUtils.java" -Raw
$door = Get-Content "$root/src/main/java/block/Door001Block.java" -Raw
$network = Get-Content "$root/src/main/java/RobmodMod.java" -Raw
if ($render -match 'blaze3d.buffers.GpuBuffer|bindTexture|mulPose\(Axis' -or $render -notmatch 'getCompiledPipeline') { throw 'Rendering migration incomplete' }
if ($door -notmatch 'PushReaction.POPPED') { throw 'Door reaction migration missing' }
if ($network -notmatch 'super RegistryFriendlyByteBuf' -or $network -notmatch 'message.register\(registrar\)') { throw 'Network migration missing' }
$feature = Get-Content "$root/src/main/java/worldgen/TOWWFeature.java" -Raw
$features = Get-Content "$root/src/main/java/worldgen/TOWWFeatures.java" -Raw
$command = Get-Content "$root/src/main/java/worldgen/TOWWCommand.java" -Raw
$state = Get-Content "$root/src/main/java/worldgen/TOWWState.java" -Raw
if ($feature -match 'Feature<|FeaturePlaceContext|NoneFeatureConfiguration|super\(|getStructureManager|structureManager\(' -or $feature -notmatch 'implements Feature|boolean place\(WorldGenLevel|getStructureTemplateManager\(') { throw 'TOWW feature migration missing' }
if ($features -match 'Feature<\?>' -or $features -notmatch 'DeferredRegister<Feature>') { throw 'TOWW feature registry migration missing' }
if ($command -match 'LevelBasedPermissionSet\.OWNER, "",' -or $command -notmatch 'LevelBasedPermissionSet\.OWNER, Component\.literal') { throw 'TOWW command source migration missing' }
if ($state -notmatch '\(StateHolder\).*setValue') { throw 'TOWW state-holder migration missing' }
if ((Get-FileHash "$root/src/main/java/Unrelated.java").Hash -ne $unrelated) { throw 'Unrelated source changed' }
if ((Get-FileHash "$root/src/main/java/unsupported/RenderUtils.java").Hash -ne $unsupportedHash) { throw 'Nonidentity transform was altered' }
if ((Get-Content "$root/src/main/java/four-argument-transform/RenderUtils.java" -Raw) -match 'new Vector3f\(\), new Matrix4f\(\)') { throw 'Known identity transform was not migrated' }
$before = @(Get-ChildItem "$root/src/main/java" -Recurse -File | Get-FileHash | ForEach-Object Hash)
& "$target/Repair-Known263Apis.ps1" -ProjectRoot $root -NeoVersion '26.3.0.22-beta'
$after = @(Get-ChildItem "$root/src/main/java" -Recurse -File | Get-FileHash | ForEach-Object Hash)
if (Compare-Object $before $after) { throw 'Repair is not idempotent' }
$rejected = $false
try { & "$target/Repair-Known263Apis.ps1" -ProjectRoot $root -NeoVersion '26.2.0.72' } catch { $rejected = $true }
if (-not $rejected) { throw 'Wrong target accepted' }
Write-Host "PASS: rendering, networking, doors, unrelated text, idempotence, target guard. $root"

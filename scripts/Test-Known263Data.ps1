$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../targets/rb-26.2-to-26.3/lib/Known263Data.ps1')
$root=Join-Path $env:TEMP ('rb-data-test-'+[guid]::NewGuid().ToString('N'))
$res=Join-Path $root 'src/main/resources'
New-Item -ItemType Directory -Path "$res/data/example/advancement","$res/assets/example" -Force | Out-Null
'{"pack":{"description":"Keep me","pack_format":121,"min_format":107,"max_format":107},"custom":{"keep":true}}' | Set-Content "$res/pack.mcmeta"
'{"criteria":{"unlocked":{"trigger":"minecraft:recipe_unlocked","conditions":{"recipe":"example:test"}}},"requirements":[["unlocked"]],"rewards":{"recipes":["example:test"]}}' | Set-Content "$res/data/example/advancement/test.json"
'{"recipe":"do not alter unrelated JSON"}' | Set-Content "$res/assets/example/model.json"
$before=(Get-FileHash "$res/assets/example/model.json").Hash
$changes=@(Update-Known263Data $root)
$j=Get-Content "$res/data/example/advancement/test.json" -Raw | ConvertFrom-Json
if($changes.Count -ne 2 -or $j.criteria.unlocked.conditions.recipes -ne 'example:test' -or $j.requirements[0][0] -ne 'unlocked' -or $j.rewards.recipes[0] -ne 'example:test'){throw 'Advancement preservation failed'}
$pack=Get-Content "$res/pack.mcmeta" -Raw | ConvertFrom-Json
if($pack.pack.description -ne 'Keep me' -or !$pack.custom.keep -or $pack.pack.PSObject.Properties['min_format']){throw 'Metadata preservation failed'}
if((Get-FileHash "$res/assets/example/model.json").Hash -ne $before){throw 'Unrelated JSON changed'}
if(@(Update-Known263Data $root).Count){throw 'Data changes not idempotent'}
Write-Host 'PASS: recipe conditions, rewards, criteria, unknown metadata, unrelated assets, idempotence.'

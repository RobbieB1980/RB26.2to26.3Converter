param([Parameter(Mandatory)][string]$PayloadRoot,[Parameter(Mandatory)][string]$InputJar)
$ErrorActionPreference='Stop'
$script=Join-Path $PayloadRoot 'tools/rb-26.2-to-26.3/legacy-pipeline/Convert-JarToProject.ps1'
$output=Join-Path ([IO.Path]::GetTempPath()) ('rb-offline-decompile-'+[guid]::NewGuid().ToString('N'))
# Block the downloader used by this pipeline without changing system networking.
function Invoke-WebRequest { throw 'Network access forbidden by offline packaging test' }
& $script -JarPath $InputJar -OutputPath $output -SourceVersion '26.2'
$java=@(Get-ChildItem (Join-Path $output 'src/main/java') -Recurse -Filter '*.java')
if($java.Count -eq 0){throw 'Packaged decompiler produced no Java sources'}
Write-Host "PASS: packaged offline decompilation produced $($java.Count) Java files. Output: $output"

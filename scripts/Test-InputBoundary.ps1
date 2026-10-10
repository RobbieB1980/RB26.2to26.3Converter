$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot '../targets/rb-26.2-to-26.3'
. (Join-Path $target 'lib/Convert-RB262To263.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$root = Join-Path $env:TEMP ('rb-262-input-boundary-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function New-FixtureJar([string]$Path, [string]$MinecraftRange) {
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry('META-INF/neoforge.mods.toml')
        $writer = [IO.StreamWriter]::new($entry.Open())
        try { $writer.Write("[[dependencies.fixture]]`nmodId=`"minecraft`"`nversionRange=`"$MinecraftRange`"`n") }
        finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
}
try {
    $valid = Join-Path $root 'valid-262.jar'
    $legacy = Join-Path $root 'legacy-1201.jar'
    New-FixtureJar $valid '[26.2]'
    New-FixtureJar $legacy '[1.20.1,1.21)'
    if (-not (Test-RB262JarInput $valid)) { throw 'Valid 26.2 NeoForge input was rejected.' }
    if (Test-RB262JarInput $legacy) { throw 'Pre-26.2 source was accepted by the strict converter.' }
    Write-Host 'PASS: the 26.2 -> 26.3 converter accepts exact 26.2 metadata and rejects 1.20.1.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}

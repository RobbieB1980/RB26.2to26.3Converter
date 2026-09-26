function Get-VineflowerJar {
    param([string]$Version = '1.12.0', [Parameter(Mandatory)][string]$CacheDir)
    # Published SHA-256 from Maven Central, verified 2026-09-26.
    # https://repo.maven.apache.org/maven2/org/vineflower/vineflower/1.12.0/vineflower-1.12.0.jar.sha256
    $hashes = @{ '1.12.0' = '1DFCFE974395734FA467CE620661C7623D05BA83670DE0529B1FBD63FF548B9D' }
    if (-not $hashes.ContainsKey($Version)) { throw "Vineflower $Version is not pinned; add its verified checksum before use." }
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $name = "vineflower-$Version.jar"
    $dest = Join-Path $CacheDir $name
    if ((Test-Path -LiteralPath $dest -PathType Leaf) -and (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $hashes[$Version]) {
        Write-Host "Using verified offline Vineflower $Version"
        return $dest
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $failures = @()
    foreach ($base in @('https://repo.maven.apache.org/maven2','https://repo1.maven.org/maven2')) {
        $url = "$base/org/vineflower/vineflower/$Version/$name"
        $partial = Join-Path $CacheDir ($name + '.' + [guid]::NewGuid().ToString('N') + '.part')
        try {
            Write-Host "Downloading pinned Vineflower from $url"
            Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing -TimeoutSec 30 | Out-Null
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $hashes[$Version]) { throw 'SHA-256 verification failed' }
            Move-Item -LiteralPath $partial -Destination $dest -Force
            return $dest
        } catch { $failures += "$base : $($_.Exception.Message)" }
        finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force } }
    }
    throw "No verified Vineflower $Version is available. Restore the JAR from the current portable package, or retry with working DNS. $($failures -join '; ')"
}

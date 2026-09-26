[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [string]$Tasks = 'build --no-daemon --stacktrace',
    [string]$LogFileName = 'compile-errors.log'
)
$ErrorActionPreference = 'Stop'
$javaRoot = Join-Path ${env:ProgramFiles} 'Eclipse Adoptium'
$javaHome = Get-ChildItem $javaRoot -Directory -Filter 'jdk-25*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $javaHome -or -not (Test-Path (Join-Path $javaHome 'bin\java.exe'))) { Write-Output 'Build unavailable: Temurin JDK 25 was not found.'; exit 2 }
$gradlew = Join-Path $ProjectRoot 'gradlew.bat'
if (-not (Test-Path $gradlew)) { Write-Output "Build unavailable: gradlew.bat is missing under $ProjectRoot. A compiled JAR does not contain a Gradle source project."; exit 2 }
$props = Join-Path $ProjectRoot 'gradle.properties'
$pin = "org.gradle.java.home=$($javaHome -replace '\\','/')"
$text = if (Test-Path $props) { Get-Content $props -Raw } else { '' }
if ($text -match '(?m)^\s*org\.gradle\.java\.home\s*=') { $text = [regex]::Replace($text, '(?m)^\s*org\.gradle\.java\.home\s*=.*$', $pin) } else { $text = $text.TrimEnd() + "`r`n$pin`r`n" }
[IO.File]::WriteAllText($props, $text)
$oldHome = $env:JAVA_HOME; $oldPath = $env:PATH
try {
    $env:JAVA_HOME = $javaHome
    $env:PATH = (Join-Path $javaHome 'bin') + [IO.Path]::PathSeparator + $oldPath
    Push-Location $ProjectRoot
    try {
        # Tee keeps the complete diagnostic log while forwarding Gradle output
        # line-by-line to the GUI process.
        & cmd /c ("gradlew.bat {0}" -f $Tasks) 2>&1 | Tee-Object -FilePath $LogFileName
        $exitCode = $LASTEXITCODE
    }
    finally { Pop-Location }
}
finally { $env:JAVA_HOME = $oldHome; $env:PATH = $oldPath }
Write-Host "JAVA_HOME=$javaHome"
Write-Host "Gradle exit code: $exitCode"
Write-Host "Log: $(Join-Path $ProjectRoot $LogFileName)"
@(
    '# Compile diagnostic report',
    '',
    "- Exit code: $exitCode",
    "- Result: $(if ($exitCode -eq 0) { 'Gradle build succeeded' } else { 'Gradle build needs follow-up' })",
    "- Log: $LogFileName"
) | Set-Content (Join-Path $ProjectRoot 'COMPILE_REPORT.md') -Encoding UTF8
exit $exitCode

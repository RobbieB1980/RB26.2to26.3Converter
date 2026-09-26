function ConvertFrom-LegacyAstWorkerProcessResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$Stdout = '',
        [AllowEmptyString()][string]$Stderr = ''
    )

    if ([string]::IsNullOrWhiteSpace($Stdout)) {
        throw "AST worker returned no JSON (exit $ExitCode). stderr: $Stderr"
    }
    try {
        $response = $Stdout | ConvertFrom-Json
    }
    catch {
        throw "AST worker returned invalid JSON (exit $ExitCode): $($_.Exception.Message). stderr: $Stderr"
    }
    if ([int]$response.protocolVersion -ne 1) {
        throw "AST worker protocol mismatch: expected 1, received $($response.protocolVersion)"
    }

    $diagnostics = @($response.diagnostics | ForEach-Object { [string]$_ })
    if ($ExitCode -ne 0) {
        $detail = if ($diagnostics.Count -gt 0) { $diagnostics -join '; ' } elseif ($Stderr) { $Stderr } else { 'no diagnostics' }
        throw "AST worker failed with exit $ExitCode ($($response.status)): $detail"
    }
    if ([string]$response.status -ne 'ok') {
        throw "AST worker returned unexpected status '$($response.status)' with exit 0"
    }

    foreach ($field in @('parsedFiles', 'parseFailures', 'declaredTypes', 'imports', 'diagnostics')) {
        if (-not ($response.PSObject.Properties.Name -contains $field)) {
            throw "AST worker response is missing required field '$field'"
        }
    }
    return $response
}

function Invoke-LegacyAstWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [string[]]$Classpath = @(),
        [Parameter(Mandatory)][string]$WorkerRoot
    )

    $resolvedSource = (Resolve-Path -LiteralPath $SourceRoot).Path
    $resolvedWorker = (Resolve-Path -LiteralPath $WorkerRoot).Path
    $workerLib = Join-Path $resolvedWorker 'lib'
    if (-not (Get-ChildItem -LiteralPath $workerLib -Filter 'legacy-java-ast-worker*.jar' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw "AST worker distribution is incomplete: $resolvedWorker"
    }

    if (-not (Get-Command Resolve-Java -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'ConversionCore.ps1')
    }
    $java = Resolve-Java -MinimumMajor 25 -ForTool 'JavaParser AST worker'
    $request = [ordered]@{
        protocolVersion = 1
        operation = 'analyze'
        sourceRoot = $resolvedSource
        classpath = @($Classpath | ForEach-Object { [IO.Path]::GetFullPath($_) })
    } | ConvertTo-Json -Compress

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $java.Path
    $startInfo.Arguments = '-cp "' + (Join-Path $workerLib '*') + '" rb.legacy.ast.Main'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'AST worker process did not start' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($request)
        $process.StandardInput.Close()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        return ConvertFrom-LegacyAstWorkerProcessResult -ExitCode $process.ExitCode -Stdout $stdout -Stderr $stderr
    }
    finally {
        $process.Dispose()
    }
}

function Compare-LegacyAndAstInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][pscustomobject]$AstResult
    )

    $resolvedSource = (Resolve-Path -LiteralPath $SourceRoot).Path
    $javaRoot = Join-Path $resolvedSource 'src\main\java'
    if (-not (Test-Path -LiteralPath $javaRoot -PathType Container)) { $javaRoot = $resolvedSource }

    $legacy = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($file in @(Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $packageName = ''
        $packageMatch = [regex]::Match($text, '(?m)^\s*package\s+([\w.$]+)\s*;')
        if ($packageMatch.Success) { $packageName = $packageMatch.Groups[1].Value }

        foreach ($match in [regex]::Matches($text, '(?m)^\s*import\s+(?:static\s+)?([\w.$]+)(?:\.\*)?\s*;')) {
            $null = $legacy.Add('import:' + $match.Groups[1].Value)
        }
        foreach ($match in [regex]::Matches($text, '(?m)^(?:(?:public|protected|private|abstract|final|sealed|non-sealed|static)\s+)*(?:class|interface|enum|record|@interface)\s+([\w$]+)')) {
            $name = $match.Groups[1].Value
            $qualified = if ($packageName) { $packageName + '.' + $name } else { $name }
            $null = $legacy.Add('type:' + $qualified)
        }
    }

    $ast = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($name in @($AstResult.declaredTypes)) { $null = $ast.Add('type:' + [string]$name) }
    foreach ($name in @($AstResult.imports)) { $null = $ast.Add('import:' + [string]$name) }

    $missingFromAst = @($legacy | Where-Object { -not $ast.Contains($_) } | Sort-Object)
    $onlyInAst = @($ast | Where-Object { -not $legacy.Contains($_) } | Sort-Object)
    return [pscustomobject]@{
        MissingFromAst = $missingFromAst
        OnlyInAst = $onlyInAst
        ParseFailures = @($AstResult.parseFailures)
    }
}

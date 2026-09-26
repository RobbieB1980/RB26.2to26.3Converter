function Get-ReleaseIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VersionPropsPath)

    [xml]$versionProps = Get-Content -LiteralPath $VersionPropsPath -Raw
    $version = [string]$versionProps.Project.PropertyGroup.Version
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Version missing from $VersionPropsPath"
    }
    return [pscustomobject]@{
        Version = $version
        Tag = "v$version"
        Name = "RB Legacy Java Converter $version"
    }
}

param(
    [Parameter(Mandatory = $true)][string]$GodotPath,
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [ValidateRange(1, 65535)][int]$Port = 8767
)
$ErrorActionPreference = 'Stop'
$executable = (Resolve-Path -LiteralPath $GodotPath).Path
$projectDirectory = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath (Join-Path $projectDirectory 'project.godot'))) {
    throw 'ProjectPath must contain the prepared Material Maker project.godot.'
}
# Hidden startup is intended for background verification. For interactive editing,
# use the direct Godot command documented in README.md.
Start-Process -FilePath $executable -WindowStyle Hidden -PassThru `
    -ArgumentList @('--path', ('"' + $projectDirectory + '"'), '--no-splash', "--mcp-port=$Port") `
    -WorkingDirectory $projectDirectory

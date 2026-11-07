param(
    [string] $JacketCompiler = 'jaic.exe'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$output = Join-Path $root 'bin'
$candidate = Join-Path $output 'ootss-cmd-jacket-build.exe'
$executable = Join-Path $output 'ootss-cmd.exe'

if (!(Test-Path -LiteralPath $JacketCompiler -PathType Leaf)) {
    $command = Get-Command $JacketCompiler -ErrorAction SilentlyContinue
    if (!$command) { throw "Jacket compiler not found: $JacketCompiler" }
    $JacketCompiler = $command.Source
}

New-Item -ItemType Directory -Path $output -Force | Out-Null
Push-Location $root
try {
    & $JacketCompiler 'src/main.jai' -optimized -I modules -exe $candidate -no_color
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'Jacket did not produce the console executable.'
    }

    # Jacket's direct build starts reliably. The original metaprogram's GUI
    # workspace output does not, so set the PE subsystem on that direct build.
    $bytes = [IO.File]::ReadAllBytes($candidate)
    if ($bytes.Length -lt 0x100 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0x5a4d) {
        throw 'Jacket produced an invalid DOS header.'
    }
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($pe -lt 0 -or $pe + 0x100 -gt $bytes.Length -or
        [BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes, $pe + 24) -ne 0x20b) {
        throw 'Jacket produced an invalid PE32+ header.'
    }
    $subsystem = $pe + 24 + 68
    if ([BitConverter]::ToUInt16($bytes, $subsystem) -ne 3) {
        throw 'Expected a console subsystem before the GUI patch.'
    }
    $bytes[$subsystem] = 2
    $bytes[$subsystem + 1] = 0
    [IO.File]::WriteAllBytes($candidate, $bytes)

    $sourceData = Join-Path $root 'data'
    $targetData = Join-Path $output 'data'
    Get-ChildItem -LiteralPath $sourceData -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($sourceData.Length).TrimStart('\', '/')
        $normalized = $relative.Replace('\', '/')
        if ($normalized -match '^fonts/' -and $normalized -ne 'fonts/Meslo-LG-Mono-Nerd-Regular.ttf') { return }
        if ($_.Extension -ieq '.sav' -or $normalized -ieq 'markers.json') { return }
        $target = Join-Path $targetData $relative
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force
    }
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $output 'LICENSE') -Force
    $config = Join-Path $output 'config.rc'
    if (!(Test-Path -LiteralPath $config)) {
        Copy-Item -LiteralPath (Join-Path $root 'config.rc') -Destination $config
    }

    Copy-Item -LiteralPath $candidate -Destination $executable -Force
    # A build produced inside an isolated low-integrity process can carry that
    # label into Explorer. The helper must match the game's normal integrity.
    & icacls.exe $executable /setintegritylevel M | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not set medium integrity on the EXE. Run this build from a normal Windows terminal.'
    }
    Write-Output "Built $executable"
} finally {
    if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force }
    Pop-Location
}

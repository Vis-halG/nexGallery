param([string]$Bundle = 'build/windows/x64/runner/Release')
$ErrorActionPreference = 'Stop'
$required = @(
    'nex_gallery.exe', 'flutter_windows.dll', 'data/icudtl.dat',
    'data/app.so', 'server/bin/nexgallery_server.exe', 'server/lib/sqlite3.dll'
)
foreach ($runtime in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    $required += $runtime
    $required += ('server/bin/' + $runtime)
}
foreach ($relative in $required) {
    $file = Join-Path $Bundle $relative
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) {
        throw "Windows distribution is incomplete: $relative"
    }
}
Write-Output 'PASS: Windows app, standalone agent, SQLite and app-local C++ runtimes are bundled.'

param([Parameter(Mandatory = $true)][string[]]$Files)
$ErrorActionPreference = 'Stop'

# An owner-provided trusted certificate is optional for the direct-download
# channel. Never generate a self-signed certificate and call it trusted.
if (-not $env:WINDOWS_CERT_BASE64) {
    Write-Output 'Windows Authenticode certificate is not configured; publishing an unsigned installer with SHA-256 verification.'
    exit 0
}
if (-not $env:WINDOWS_CERT_PASSWORD) { throw 'WINDOWS_CERT_PASSWORD is required.' }
$signTool = Get-ChildItem -Path 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signTool) { throw 'Windows SDK SignTool was not found.' }
$certificateFile = Join-Path $env:RUNNER_TEMP 'nexgallery-codesign.pfx'
$imported = $null
try {
    [IO.File]::WriteAllBytes($certificateFile, [Convert]::FromBase64String($env:WINDOWS_CERT_BASE64))
    $password = ConvertTo-SecureString -String $env:WINDOWS_CERT_PASSWORD -AsPlainText -Force
    $imported = Import-PfxCertificate -FilePath $certificateFile -CertStoreLocation Cert:\CurrentUser\My -Password $password |
        Where-Object { $_.HasPrivateKey } | Select-Object -First 1
    if (-not $imported) { throw 'The code-signing certificate has no private key.' }
    foreach ($path in $Files) {
        $resolved = (Resolve-Path -LiteralPath $path).Path
        & $signTool.FullName sign /sha1 $imported.Thumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $resolved
        if ($LASTEXITCODE -ne 0) { throw 'Windows code signing failed.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $resolved
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $imported.Thumbprint) {
            throw 'Windows signature verification failed.'
        }
    }
} finally {
    if ($imported) { Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $imported.Thumbprint) -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $certificateFile) { Remove-Item -LiteralPath $certificateFile }
}

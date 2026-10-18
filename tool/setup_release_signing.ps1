# One-time setup of the Android release signing key used for in-app updates.
#
#   powershell -ExecutionPolicy Bypass -File tool\setup_release_signing.ps1
#
# Creates nexgallery-release.jks in Documents\nexGallery-signing, writes the
# ignored android\key.properties for local release builds, and stores the key
# in this repository's GitHub Actions secrets so every release is signed with
# the same key. Android only installs an update signed by the same key, so
# keep the password and a copy of the .jks file somewhere safe.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$folder = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'nexGallery-signing'
$keystore = Join-Path $folder 'nexgallery-release.jks'
$alias = 'nexgallery'

if (Test-Path $keystore) {
    Write-Host "A key already exists at $keystore. Delete it first only if no phone has a build signed with it." -ForegroundColor Yellow
    exit 1
}
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw 'Sign in to GitHub first: gh auth login' }
$keytool = Get-Command keytool -ErrorAction SilentlyContinue
if (-not $keytool) {
    $keytool = Get-ChildItem 'C:\Program Files\*\jdk*\bin\keytool.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $keytool) { throw 'keytool was not found. Install a JDK (17 or newer).' }

$bytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$password = [Convert]::ToBase64String($bytes) -replace '[+/=]', 'x'

New-Item -ItemType Directory -Force $folder | Out-Null
& $keytool.Source -genkeypair -keystore $keystore -storetype PKCS12 -alias $alias `
    -keyalg RSA -keysize 4096 -validity 10000 -storepass $password -keypass $password `
    -dname 'CN=nexGallery, O=TheNex' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'keytool could not create the key.' }

# Local release builds use the same key. key.properties is ignored by Git.
$storeFile = $keystore -replace '\\', '/'
@(
    "storePassword=$password",
    "keyPassword=$password",
    "keyAlias=$alias",
    "storeFile=$storeFile"
) | Set-Content -Encoding ascii (Join-Path $repo 'android\key.properties')

Push-Location $repo
try {
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($keystore)) | gh secret set ANDROID_KEYSTORE_BASE64
    $password | gh secret set ANDROID_KEYSTORE_PASSWORD
    $alias | gh secret set ANDROID_KEY_ALIAS
    # Publish the first signed release from main right away.
    gh workflow run release.yml --ref main
} finally {
    Pop-Location
}

Write-Host ''
Write-Host 'Release signing is ready. The first release is building now:' -ForegroundColor Green
Write-Host 'https://github.com/Vis-halG/nexGallery/actions/workflows/release.yml'
Write-Host "Key file : $keystore"
Write-Host "Password : $password"
Write-Host ''
Write-Host 'Save the password in a password manager and copy the .jks file to a' -ForegroundColor Yellow
Write-Host 'pen drive. Without them, phones cannot receive updates.' -ForegroundColor Yellow

# Install latest On-Chain Oracle AI release APK to a connected Android phone (e.g. Galaxy S23).
# Prerequisites: USB debugging enabled, phone connected, Flutter SDK on PATH.

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

Write-Host "Building release APK (includes latest Citadel + UI updates)..." -ForegroundColor Cyan
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
flutter pub get
flutter build apk --release
if ($LASTEXITCODE -ne 0) {
    Write-Host "Release build failed; building debug APK (same UI code)..." -ForegroundColor Yellow
    flutter build apk --debug
}

$Apk = Join-Path $ProjectRoot "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $Apk)) {
    $Apk = Join-Path $ProjectRoot "build\app\outputs\flutter-apk\app-debug.apk"
}
if (-not (Test-Path $Apk)) {
    throw "No APK found under build\app\outputs\flutter-apk\"
}

$DesktopApk = Join-Path ([Environment]::GetFolderPath("Desktop")) "On-Chain-Oracle-AI-latest.apk"
Copy-Item -Force $Apk $DesktopApk
Write-Host "Copied APK to Desktop: $DesktopApk" -ForegroundColor Cyan

Write-Host "`nLooking for Android devices..." -ForegroundColor Cyan
flutter devices

$deviceList = flutter devices --machine 2>$null | ConvertFrom-Json
$phone = $deviceList | Where-Object {
    $_.targetPlatform -eq 'android' -and $_.emulator -eq $false
} | Select-Object -First 1

if ($phone) {
    Write-Host "Installing to $($phone.name) ($($phone.id))..." -ForegroundColor Green
    # Prefer debug APK when release R8 is disabled on dev machines; same Dart/UI code.
    if (Test-Path (Join-Path $ProjectRoot "build\app\outputs\flutter-apk\app-release.apk")) {
        flutter install --device-id $phone.id --release
    } else {
        flutter install --device-id $phone.id
    }
    Write-Host "Done. Open the app and check Profile > About for Version 1.0.1 (Build 2)." -ForegroundColor Green
} else {
    Write-Host "No physical phone detected. Copy this APK to your S23 and install manually:" -ForegroundColor Yellow
    Write-Host $Apk
    Write-Host "Uninstall the old 'On-Chain Oracle AI' app first, then open the APK on your phone." -ForegroundColor Yellow
}

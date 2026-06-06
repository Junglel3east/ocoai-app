# Restore On-Chain Oracle AI to the oco-complete-stable snapshot.
# Use when you need to revert to the last known-good full build:
#   Oracle Vision, Oracle Desk, Citadel leverage (setup + market dialog), BloFin live price.
#
# Usage (from repo root or scripts folder):
#   .\scripts\restore_oco_complete_stable.ps1

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$restores = @(
    @{ backup = "lib\main.dart.oco-complete-stable.backup"; target = "lib\main.dart" },
    @{ backup = "lib\screens\citadel_setup_dialog.dart.oco-complete-stable.backup"; target = "lib\screens\citadel_setup_dialog.dart" },
    @{ backup = "lib\screens\oracle_vision_screen.dart.oco-complete-stable.backup"; target = "lib\screens\oracle_vision_screen.dart" },
    @{ backup = "lib\screens\oracle_desk_screen.dart.oco-complete-stable.backup"; target = "lib\screens\oracle_desk_screen.dart" },
    @{ backup = "lib\services\oracle_vision_service.dart.oco-complete-stable.backup"; target = "lib\services\oracle_vision_service.dart" },
    @{ backup = "lib\services\oracle_desk_service.dart.oco-complete-stable.backup"; target = "lib\services\oracle_desk_service.dart" },
    @{ backup = "backend\api.py.oco-complete-stable.backup"; target = "backend\api.py" },
    @{ backup = "backend\test_citadel_leverage.py.oco-complete-stable.backup"; target = "backend\test_citadel_leverage.py" }
)

Write-Host "Restoring oco-complete-stable snapshot..." -ForegroundColor Cyan
foreach ($item in $restores) {
    $backupPath = Join-Path $ProjectRoot $item.backup
    $targetPath = Join-Path $ProjectRoot $item.target
    if (-not (Test-Path $backupPath)) {
        throw "Missing backup: $($item.backup)"
    }
    Copy-Item -Force $backupPath $targetPath
    Write-Host "  restored $($item.target)" -ForegroundColor Green
}

Write-Host "`nDone. Rebuild the app:" -ForegroundColor Cyan
Write-Host "  flutter pub get"
Write-Host "  flutter build apk --release"
Write-Host "  flutter install -d <device-id> --release"
Write-Host "`nOr revert via git tag: git checkout oco-complete-stable" -ForegroundColor Yellow

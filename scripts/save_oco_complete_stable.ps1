# Save the current On-Chain Oracle AI build as the oco-complete-stable snapshot.
# Known-good baseline includes:
#   - Oracle Vision, Oracle Desk, Citadel market + limit orders (demo/live routing)
#   - Automated daily analysis (BTC, ETH, SOL, XRP @ 7:30 AM CST)
#   - Post-fill success screen, BloFin live price, margin-safe order sizing
#
# Usage (from repo root or scripts folder):
#   .\scripts\save_oco_complete_stable.ps1

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$snapshots = @(
    @{ source = "lib\main.dart"; backup = "lib\main.dart.oco-complete-stable.backup" },
    @{ source = "lib\screens\citadel_setup_dialog.dart"; backup = "lib\screens\citadel_setup_dialog.dart.oco-complete-stable.backup" },
    @{ source = "lib\screens\oracle_vision_screen.dart"; backup = "lib\screens\oracle_vision_screen.dart.oco-complete-stable.backup" },
    @{ source = "lib\screens\oracle_desk_screen.dart"; backup = "lib\screens\oracle_desk_screen.dart.oco-complete-stable.backup" },
    @{ source = "lib\services\oracle_vision_service.dart"; backup = "lib\services\oracle_vision_service.dart.oco-complete-stable.backup" },
    @{ source = "lib\services\oracle_desk_service.dart"; backup = "lib\services\oracle_desk_service.dart.oco-complete-stable.backup" },
    @{ source = "lib\services\daily_analysis_store.dart"; backup = "lib\services\daily_analysis_store.dart.oco-complete-stable.backup" },
    @{ source = "lib\services\notification_service.dart"; backup = "lib\services\notification_service.dart.oco-complete-stable.backup" },
    @{ source = "backend\api.py"; backup = "backend\api.py.oco-complete-stable.backup" },
    @{ source = "backend\test_citadel_leverage.py"; backup = "backend\test_citadel_leverage.py.oco-complete-stable.backup" }
)

Write-Host "Saving oco-complete-stable snapshot..." -ForegroundColor Cyan
foreach ($item in $snapshots) {
    $sourcePath = Join-Path $ProjectRoot $item.source
    $backupPath = Join-Path $ProjectRoot $item.backup
    if (-not (Test-Path $sourcePath)) {
        throw "Missing source: $($item.source)"
    }
    Copy-Item -Force $sourcePath $backupPath
    Write-Host "  saved $($item.backup)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Optional - pin git tag to this commit:" -ForegroundColor Cyan
Write-Host '  git tag -f oco-complete-stable'
Write-Host '  git push origin oco-complete-stable --force'

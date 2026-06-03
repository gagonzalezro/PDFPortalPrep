param(
    [string]$MsiPath
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$bundleDir = Join-Path $root "desktop\src-tauri\target\release\bundle\msi"

if (-not $MsiPath) {
    $latest = Get-ChildItem -Path $bundleDir -Filter *.msi -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        throw "No se encontro ningun .msi en $bundleDir"
    }
    $MsiPath = $latest.FullName
}

if (-not (Test-Path $MsiPath)) {
    throw "No existe el MSI: $MsiPath"
}

$logPath = Join-Path $env:TEMP "pdf-portal-prep-msi-install.log"
$arguments = "/i `"$MsiPath`" /L*v `"$logPath`""

Write-Host "Lanzando instalacion MSI con elevacion explicita:" -ForegroundColor Yellow
Write-Host "  $MsiPath"
Write-Host "Log: $logPath"

Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Verb RunAs -Wait

Write-Host "Instalacion MSI finalizada. Revisa el log si necesitas diagnostico adicional:" -ForegroundColor Green
Write-Host "  $logPath"
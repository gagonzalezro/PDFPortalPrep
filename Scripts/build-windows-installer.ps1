$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$desktop = Join-Path $root "desktop"
$bundle = Join-Path $desktop "src-tauri\target\release\bundle"
$tauriCmd = Join-Path $desktop "node_modules\.bin\tauri.cmd"

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "cargo no esta disponible en PATH. Instala Rust con rustup antes de generar el instalador."
}

Set-Location $desktop

if (-not (Test-Path $tauriCmd)) {
    $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
    if (-not $pnpm) {
        throw "No se encontro desktop/node_modules/.bin/tauri.cmd y pnpm no esta disponible en PATH. Instala dependencias en desktop antes de generar el instalador."
    }

    & $pnpm.Source config set verify-deps-before-run false | Out-Null
    & $pnpm.Source install --frozen-lockfile

    if (-not (Test-Path $tauriCmd)) {
        throw "No se encontro node_modules/.bin/tauri.cmd despues de instalar dependencias."
    }
}

& $tauriCmd build

Write-Host "Instaladores generados en $bundle" -ForegroundColor Green

if (Test-Path (Join-Path $bundle "msi")) {
    Write-Host "MSI:  $bundle\msi" -ForegroundColor Green
}

if (Test-Path (Join-Path $bundle "nsis")) {
    Write-Host "NSIS: $bundle\nsis" -ForegroundColor Green
}
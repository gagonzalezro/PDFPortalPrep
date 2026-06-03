#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP_DIR="$ROOT_DIR/desktop"
BUNDLE_DIR="$DESKTOP_DIR/src-tauri/target/release/bundle"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Este script debe ejecutarse desde macOS para generar .app/.dmg nativos." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild no esta disponible en PATH. Instala Xcode y las Command Line Tools antes de continuar." >&2
  exit 1
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm no esta disponible en PATH. Instala Node + pnpm antes de generar el instalador." >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo no esta disponible en PATH. Instala Rust con rustup antes de generar el instalador." >&2
  exit 1
fi

cd "$DESKTOP_DIR"
pnpm config set verify-deps-before-run false >/dev/null
pnpm install --frozen-lockfile

if [[ ! -x "./node_modules/.bin/tauri" ]]; then
  echo "No se encontro node_modules/.bin/tauri despues de instalar dependencias." >&2
  exit 1
fi

./node_modules/.bin/tauri build

echo "Bundles generados en:"
echo "  $BUNDLE_DIR"
echo "Salidas esperadas en macOS:"
echo "  $BUNDLE_DIR/macos"
echo "  $BUNDLE_DIR/dmg"
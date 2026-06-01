# PDF Portal Prep — shell desktop (Tauri v2 + React/TS + Rust)

Shell multiplataforma de la migración. La lógica PDF vive en el crate `../pdf_core`
(escalera DPI, guard output ≤ input, conteo de páginas). Esta carpeta solo aporta
la UI React y los comandos Tauri (`scan_pdf`, `process_pdfs`) que la invocan.

## Requisitos

- Rust (rustup) · Node + npm/pnpm · **Ghostscript** (`gs`) en el PATH (motor de compresión).

## Ejecutar en desarrollo

```bash
cd desktop
npm install
npm run tauri dev
```

## Build de producción

```bash
npm run tauri build
```

## ⚠️ Gotcha del entorno: `npm` está aliaseado a `pnpm`

pnpm aquí corre en modo estricto y, antes de cada script, hacía un
`verify-deps-before-run` que abortaba por el build ignorado de `esbuild`.
Ya está resuelto con:

```bash
pnpm config set verify-deps-before-run false
```

Si en otra máquina vuelve a fallar con `ERR_PNPM_IGNORED_BUILDS`, ejecuta los
binarios directamente, que evitan el wrapper:

```bash
node_modules/.bin/vite build      # frontend
node_modules/.bin/tauri dev       # app
```

Por eso `tauri.conf.json` usa `node_modules/.bin/vite` en `beforeDevCommand`
en vez de `npm run dev`.

## Estado

Fase 1 (rebanada vertical): comprimir 1 PDF end-to-end. Merge, validación de
cifrado/interactivos y batch llegan en Fase 2. Ver
`~/.claude/plans/quiero-implementar-esto-en-foamy-wave.md`.

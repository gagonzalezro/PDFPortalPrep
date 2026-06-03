# PDF Portal Prep

Aplicación de escritorio para **preparar PDFs antes de subirlos a portales o enviarlos por email**:
comprimir hasta un tamaño objetivo, combinar varios documentos en uno y validar el archivo
(páginas, cifrado, elementos interactivos) sin perder legibilidad.

El motor de compresión es **Ghostscript**, gobernado por una *escalera de DPI*: arranca en el
peldaño de mayor calidad del perfil elegido y solo baja lo justo para alcanzar el tamaño objetivo.
Nunca cruza al territorio de un perfil más agresivo de forma silenciosa; si llega al suelo sin
cumplir el objetivo, lo avisa en lugar de entregar un documento ilegible.

## Estado del proyecto

El repositorio contiene **dos implementaciones conviviendo durante la migración**:

| Implementación | Stack | Ubicación | Estado |
|---|---|---|---|
| App original | SwiftUI · macOS 14+ · PDFKit | raíz (`Views/`, `Services/`, `Models/`) | Legado de referencia |
| App de escritorio | Tauri v2 · React 19 + TS · núcleo Rust | `desktop/` + `pdf_core/` | Ruta activa para Windows y macOS |

El crate **`pdf_core`** es un espejo en Rust de la lógica de los `Services/` Swift (compresión,
merge y validación). La escalera DPI y la calidad JPEG son un contrato congelado: la app nueva
debe igualar bit a bit el comportamiento de la original.

## Ruta recomendada por plataforma

- **Windows**: usar la app Tauri de `desktop/`. El código Swift raíz sigue siendo macOS-only.
- **macOS**: para distribución nueva, usar también la app Tauri. La app Swift queda como referencia funcional durante la migración.
- **Núcleo compartido**: `pdf_core/` ya localiza Ghostscript tanto en rutas Unix como en instalaciones típicas de Windows (`gswin64c.exe`, `gswin32c.exe`, `gs.exe`).

## Perfiles de compresión

| Perfil | Escalera DPI | Calidad JPEG | Uso |
|---|---|---|---|
| **Ligera** | 220 → 180 → 150 | 0.85 | Máxima legibilidad e imágenes |
| **Balanceada** | 150 → 130 → 110 | 0.72 | Recomendada para email/subidas |
| **Máxima** | 110 → 90 → 72 | 0.55 | Reducción agresiva (avisa de pérdida de calidad) |

## Acciones

- **Comprimir** un PDF hasta un tamaño objetivo.
- **Combinar y comprimir** varios PDFs en un único documento.
- **Escanear / validar**: tamaño, número de páginas, cifrado y elementos interactivos.

## Estructura del repositorio

```
.
├── Views/ Models/ Services/ Utilities/   App SwiftUI original (macOS)
├── Resources/                            Iconos y plantilla de OAuth
├── Tests/                                Tests de la app Swift
├── Package.swift                         Manifiesto Swift Package Manager
├── pdf_core/                             Núcleo de procesamiento PDF en Rust
└── desktop/                              Shell Tauri v2 + React/TS (UI nueva)
    └── src-tauri/                        Comandos Tauri (scan_pdf, process_pdfs)
```

## Requisitos

- **Ghostscript** en el `PATH` — `gs` en macOS/Linux, `gswin64c.exe`/`gswin32c.exe`/`gs.exe` en Windows.
    En esta máquina Windows también quedó validada la ruta local `C:\Users\Wilme\AppData\Local\Ghostscript\bin\gswin64c.exe`.
- App Swift: macOS 14+ y Xcode / Swift 6 toolchain.
- Migración Tauri: Rust (rustup), Node.js LTS y pnpm.
- Validado en este repo sobre Windows con `cargo` en `C:\Users\Wilme\.cargo\bin\cargo.exe` y Node.js `v24.16.0`.

## Ejecutar

### App SwiftUI original (macOS)

```bash
swift build
swift run PDFPortalPrep
swift test            # ejecutar los tests
```

### Migración Tauri (desktop)

```bash
cd desktop
npm install
npm run tauri dev     # desarrollo
npm run tauri build   # build de producción
```

Para Windows, el flujo validado en este repo usa los scripts de `Scripts/` desde la raíz del proyecto.

## Instaladores

Los instaladores nativos se generan desde `desktop/` con Tauri v2:

- **Windows**: `powershell -ExecutionPolicy Bypass -File .\Scripts\build-windows-installer.ps1`
- **Instalar MSI en Windows**: `powershell -ExecutionPolicy Bypass -File .\Scripts\install-windows-msi.ps1`
- **macOS**: `bash ./Scripts/build-macos-installer.sh`

El script de Windows usa `desktop/node_modules/.bin/tauri.cmd` como ruta preferida y solo intenta usar `pnpm` si falta la instalación local de dependencias. El script de macOS valida que se ejecute en una Mac real, que `xcodebuild` este disponible y que el bundle se genere usando `desktop/node_modules/.bin/tauri`, que es la misma ruta de build validada para Windows.

Salida esperada:

- Windows: `desktop/src-tauri/target/release/bundle/msi/` y `desktop/src-tauri/target/release/bundle/nsis/`
- macOS: `desktop/src-tauri/target/release/bundle/macos/` y `bundle/dmg/`

Artefactos comprobados actualmente en este workspace:

- `desktop/src-tauri/target/release/bundle/msi/PDF Portal Prep_0.1.0_x64_en-US.msi`
- `desktop/src-tauri/target/release/bundle/nsis/PDF Portal Prep_0.1.0_x64-setup.exe`

Validación operativa en Windows:

- El smoke test real de `pdf_core/` ya se ejecutó con Ghostscript en Windows para compresión y merge.
- El helper `Scripts/install-windows-msi.ps1` quedó validado y la instalación MSI se registró correctamente.
- En esta máquina, el MSI quedó instalado en `C:\Users\Wilme\AppData\Local\PDF Portal Prep\`.
- El ejecutable instalado verificado es `C:\Users\Wilme\AppData\Local\PDF Portal Prep\desktop.exe`.

> Nota: no es posible generar un `.dmg` válido desde Windows ni un `.msi` nativo desde macOS sin una cadena de build de ese sistema operativo.

## Diseño

Los diagramas PlantUML del sistema viven en `Design/`:

- `Design/architecture.puml` y `Design/architecture.png`
- `Design/class-diagram.puml` y `Design/class-diagram.png`
- `Design/macos-release-checklist.md` para firma y notarización del release macOS

> ⚠️ En `desktop/` `npm` está aliaseado a `pnpm` en modo estricto. Si aparece
> `ERR_PNPM_IGNORED_BUILDS`, ver las notas de `desktop/README.md` (se invocan los
> binarios de `node_modules/.bin/` directamente para saltar el wrapper).

## Secretos

Las credenciales de Google OAuth (`client_secret_*.json`, `Resources/GoogleOAuth.plist`)
están en `.gitignore` y **no** se versionan. Usa `Resources/GoogleOAuth.example.plist`
como plantilla para tu copia local.

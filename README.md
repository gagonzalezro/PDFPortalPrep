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
| App original | SwiftUI · macOS 14+ · PDFKit | raíz (`Views/`, `Services/`, `Models/`) | Funcional |
| Migración | Tauri v2 · React 19 + TS · núcleo Rust | `desktop/` + `pdf_core/` | Fase 2 en curso |

El crate **`pdf_core`** es un espejo en Rust de la lógica de los `Services/` Swift (compresión,
merge y validación). La escalera DPI y la calidad JPEG son un contrato congelado: la app nueva
debe igualar bit a bit el comportamiento de la original.

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

- **Ghostscript** (`gs`) en el `PATH` — motor de compresión, imprescindible en ambas apps.
- App Swift: macOS 14+ y Xcode / Swift 6 toolchain.
- Migración Tauri: Rust (rustup) y Node + pnpm.

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

> ⚠️ En `desktop/` `npm` está aliaseado a `pnpm` en modo estricto. Si aparece
> `ERR_PNPM_IGNORED_BUILDS`, ver las notas de `desktop/README.md` (se invocan los
> binarios de `node_modules/.bin/` directamente para saltar el wrapper).

## Secretos

Las credenciales de Google OAuth (`client_secret_*.json`, `Resources/GoogleOAuth.plist`)
están en `.gitignore` y **no** se versionan. Usa `Resources/GoogleOAuth.example.plist`
como plantilla para tu copia local.

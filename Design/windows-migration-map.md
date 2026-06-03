# PDF Portal Prep - Mapa de migracion Mac a Windows

## Base real inspeccionada en codigo Swift

La implementacion macOS original vive en:

- `Views/ContentView.swift`
- `Services/PDFProcessingService.swift`
- `Services/PDFCompressionService.swift`
- `Services/PDFMergeService.swift`
- `Services/PDFValidationService.swift`
- `Services/GmailIntegrationService.swift`
- `Services/ProcessingLogService.swift`

La ruta multiplataforma que debe sustituirla para Windows vive en:

- `desktop/src/App.tsx`
- `desktop/src-tauri/src/lib.rs`
- `pdf_core/src/*.rs`

## Equivalencias Mac -> Windows

| Comportamiento macOS | API/archivo actual | Equivalente Windows/Tauri | Estado |
|---|---|---|---|
| Ventana principal SwiftUI | `PDFPortalPrepApp.swift`, `ContentView.swift` | `desktop/src/App.tsx` | En migracion |
| Seleccion multiple de PDFs | `NSOpenPanel` | `@tauri-apps/plugin-dialog.open({ multiple: true })` | Portado |
| Reordenar PDFs antes de unir | `PDFFileListView` | Lista React con acciones subir/bajar | Portado |
| Comprimir 1 PDF | `PDFProcessingService.Action.compressSingle` | `process_pdfs` + `action: compressSingle` | Portado |
| Unir y comprimir varios PDFs | `PDFMergeService` + `PDFProcessingService.Action.mergeAndCompress` | `pdf_core::merge` + `process_pdfs` + UI React | Portado |
| Validacion PDF (paginas, cifrado, interactivos) | `PDFValidationService.scan` | `pdf_core::scan` | Portado |
| Ladder DPI + guard output <= input | `PDFProcessingService` + `PDFCompressionService` | `pdf_core::compress` | Portado |
| Localizacion de Ghostscript | `GhostscriptLocator.swift` | `pdf_core::ghostscript::locate()` | Portado a Windows |
| Abrir resultado | `NSWorkspace.shared.open` | comando Tauri `open_path` | Portado |
| Mostrar en Finder | `NSWorkspace.shared.activateFileViewerSelecting` | comando Tauri `reveal_in_folder` | Portado |
| Registro JSONL del proceso | `ProcessingLogService.write` | comando Tauri `write_process_log` | Portado |
| Importacion desde Gmail | `GmailIntegrationService` | Pendiente: comandos Tauri/Rust + storage seguro multiplataforma | Pendiente |
| OAuth con navegador del sistema | `NSWorkspace.shared.open(authURL)` | `open_path` o plugin opener para URL | Pendiente |
| Persistencia segura de tokens | Keychain (`Security`) | Windows Credential Manager o almacenamiento cifrado multiplataforma | Pendiente |

## APIs macOS-only detectadas

Estas APIs no deben quedar en la ruta Windows:

- `SwiftUI`
- `PDFKit`
- `Quartz`
- `AppKit`
- `NSOpenPanel`
- `NSWorkspace`
- `Security`/Keychain de macOS

## Sustitutos multiplataforma elegidos

- UI: React + Tauri
- Shell y comandos nativos: Tauri
- Motor PDF: `pdf_core` en Rust
- Merge PDF: `lopdf`
- Validacion PDF: `lopdf`
- Compresion PDF: Ghostscript
- Acciones de shell: comandos Tauri por plataforma (`cmd/start`, `explorer`, `open`, `xdg-open`)

## Estado actual del portado

### Ya migrado al escritorio Tauri

- Seleccion multiple de PDFs
- Compresion simple
- Merge + compresion
- Perfiles de compresion
- Advertencias por cifrado/interactividad
- Reordenacion de archivos
- Cancelacion de trabajo
- Acciones de resultado
- Registro de proceso

### Pendiente para paridad completa con la app macOS

- Importacion y descarga de adjuntos desde Gmail
- Almacenamiento seguro de tokens OAuth en Windows/macOS
- Afinar drag and drop si se quiere paridad visual total con la app Swift
- Verificacion end-to-end con toolchain completo (`cargo`, `pnpm`)
# macOS Release Checklist

Checklist operativo para generar, firmar y notarizar la app Tauri de PDF Portal Prep desde una Mac.

## 1. Requisitos previos

- Ejecutar el build en macOS, no en Windows.
- Tener Xcode + Command Line Tools instalados (`xcodebuild`, `notarytool`, `codesign`).
- Tener Rust, Node y `pnpm` disponibles.
- Tener acceso a un certificado `Developer ID Application` y, si se distribuye `.pkg`, también `Developer ID Installer`.
- Tener configurado un perfil de `notarytool` con credenciales de Apple Developer.

## 2. Build local

Desde la raíz del repo:

```bash
bash ./Scripts/build-macos-installer.sh
```

Salidas esperadas:

- `desktop/src-tauri/target/release/bundle/macos/`
- `desktop/src-tauri/target/release/bundle/dmg/`

Bundle esperado:

- App: `PDF Portal Prep.app`
- Identificador: `com.gustavogonzalez.pdfportalprep`

## 3. Firma del `.app`

Verificar identidad disponible:

```bash
security find-identity -v -p codesigning
```

Firmar la app si el pipeline no lo hizo ya:

```bash
codesign --force --deep --options runtime \
  --sign "Developer ID Application: TU NOMBRE O EMPRESA" \
  "desktop/src-tauri/target/release/bundle/macos/PDF Portal Prep.app"
```

Validar firma:

```bash
codesign --verify --deep --strict --verbose=2 \
  "desktop/src-tauri/target/release/bundle/macos/PDF Portal Prep.app"

spctl --assess --type execute --verbose=4 \
  "desktop/src-tauri/target/release/bundle/macos/PDF Portal Prep.app"
```

## 4. Notarización

Enviar el `.dmg` a notarización:

```bash
xcrun notarytool submit \
  "desktop/src-tauri/target/release/bundle/dmg/PDF Portal Prep_0.1.0_aarch64.dmg" \
  --keychain-profile "AC_PROFILE" \
  --wait
```

Si el nombre final del `.dmg` cambia por arquitectura o versión, sustituirlo por el artefacto real generado en `bundle/dmg/`.

## 5. Staple

Adjuntar el ticket de notarización:

```bash
xcrun stapler staple \
  "desktop/src-tauri/target/release/bundle/macos/PDF Portal Prep.app"

xcrun stapler staple \
  "desktop/src-tauri/target/release/bundle/dmg/PDF Portal Prep_0.1.0_aarch64.dmg"
```

## 6. Validación final

- Abrir la app firmada fuera de Xcode.
- Confirmar que Gatekeeper no la bloquea.
- Validar compresión y merge con Ghostscript instalado en la Mac.
- Validar Gmail con credenciales OAuth reales.
- Confirmar que el `.dmg` descargado en otra Mac se monta y abre correctamente.

## 7. Publicación

- Publicar el `.dmg` notarizado.
- Guardar huella de versión, fecha, identidad de firma y resultado de `notarytool`.
- Mantener el mismo `identifier` del bundle entre releases salvo migración explícita.
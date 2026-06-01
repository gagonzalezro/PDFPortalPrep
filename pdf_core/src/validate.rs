use crate::models::ScanResult;
use lopdf::{Dictionary, Document, Object};
use std::path::Path;

/// ¿El PDF está cifrado? Equivalente a `document.isEncrypted || isLocked`
/// de PDFKit: presencia de `/Encrypt` en el trailer.
pub fn is_encrypted(doc: &Document) -> bool {
    doc.trailer.get(b"Encrypt").is_ok()
}

fn acroform_present(doc: &Document) -> bool {
    if let Ok(Object::Reference(root_id)) = doc.trailer.get(b"Root") {
        if let Ok(catalog) = doc.get_dictionary(*root_id) {
            return catalog.get(b"AcroForm").is_ok();
        }
    }
    false
}

fn annot_is_interactive(dict: &Dictionary) -> bool {
    // Nombre de campo (/T) → es un campo de formulario.
    if dict.get(b"T").is_ok() {
        return true;
    }
    // Subtipo /Widget → control interactivo.
    if let Ok(Object::Name(sub)) = dict.get(b"Subtype") {
        return sub.as_slice() == b"Widget";
    }
    false
}

/// ¿Tiene elementos interactivos? Espejo de `PDFValidationService`:
/// anotaciones con nombre de campo o subtipo /Widget. Se añade además la
/// detección de `/AcroForm` en el catálogo (superset honesto de la lógica Swift).
pub fn has_interactive_elements(doc: &Document) -> bool {
    if acroform_present(doc) {
        return true;
    }
    for (_, page_id) in doc.get_pages() {
        let Ok(page) = doc.get_dictionary(page_id) else {
            continue;
        };
        let Ok(Object::Array(annots)) = page.get(b"Annots") else {
            continue;
        };
        for r in annots {
            let interactive = match r {
                Object::Reference(id) => doc
                    .get_dictionary(*id)
                    .map(annot_is_interactive)
                    .unwrap_or(false),
                Object::Dictionary(d) => annot_is_interactive(d),
                _ => false,
            };
            if interactive {
                return true;
            }
        }
    }
    false
}

/// Escanea un PDF. Reemplaza `PDFValidationService.scan`.
pub fn scan(path: &Path) -> ScanResult {
    let file_size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    match Document::load(path) {
        Ok(doc) => ScanResult {
            path: path.to_path_buf(),
            file_size,
            page_count: doc.get_pages().len() as u32,
            is_valid: true,
            is_encrypted: is_encrypted(&doc),
            has_interactive_elements: has_interactive_elements(&doc),
        },
        Err(_) => ScanResult {
            path: path.to_path_buf(),
            file_size,
            page_count: 0,
            is_valid: false,
            is_encrypted: false,
            has_interactive_elements: false,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lopdf::dictionary;

    #[test]
    fn detects_encrypted_via_trailer() {
        let mut doc = Document::with_version("1.5");
        assert!(!is_encrypted(&doc));
        let enc = doc.add_object(dictionary! { "Filter" => "Standard" });
        doc.trailer.set("Encrypt", Object::Reference(enc));
        assert!(is_encrypted(&doc));
    }

    #[test]
    fn detects_interactive_via_acroform() {
        let mut doc = Document::with_version("1.5");
        let acro = doc.add_object(dictionary! {});
        let catalog = doc.add_object(dictionary! {
            "Type" => "Catalog",
            "AcroForm" => Object::Reference(acro),
        });
        doc.trailer.set("Root", Object::Reference(catalog));
        assert!(has_interactive_elements(&doc));
    }

    #[test]
    fn non_interactive_catalog_is_clean() {
        let mut doc = Document::with_version("1.5");
        let catalog = doc.add_object(dictionary! { "Type" => "Catalog" });
        doc.trailer.set("Root", Object::Reference(catalog));
        assert!(!has_interactive_elements(&doc));
        assert!(!is_encrypted(&doc));
    }

    #[test]
    fn widget_annotation_is_interactive() {
        assert!(annot_is_interactive(&dictionary! { "Subtype" => "Widget" }));
        assert!(annot_is_interactive(&dictionary! { "T" => "campo1" }));
        assert!(!annot_is_interactive(&dictionary! { "Subtype" => "Link" }));
    }
}

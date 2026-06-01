use crate::cancel::CancelToken;
use crate::error::PdfError;
use lopdf::{Document, Object, ObjectId};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Une varios PDFs en uno solo preservando el número total de páginas.
/// Reemplaza `Services/PDFMergeService.swift` (PDFKit) usando `lopdf`.
pub fn merge(inputs: &[PathBuf], output: &Path, cancel: &CancelToken) -> Result<(), PdfError> {
    if inputs.is_empty() {
        return Err(PdfError::NoInput);
    }

    let mut max_id = 1;
    let mut documents_pages: BTreeMap<ObjectId, Object> = BTreeMap::new();
    let mut documents_objects: BTreeMap<ObjectId, Object> = BTreeMap::new();
    let mut document = Document::with_version("1.5");

    for path in inputs {
        cancel.check()?;
        let mut doc = Document::load(path)
            .map_err(|e| PdfError::InvalidPdf(format!("{}: {e}", path.display())))?;
        // Renumerar objetos para que no colisionen entre documentos.
        doc.renumber_objects_with(max_id);
        max_id = doc.max_id + 1;

        documents_pages.extend(
            doc.get_pages()
                .into_values()
                .map(|object_id| {
                    (
                        object_id,
                        doc.get_object(object_id).cloned().unwrap_or(Object::Null),
                    )
                })
                .collect::<BTreeMap<ObjectId, Object>>(),
        );
        documents_objects.extend(doc.objects);
    }

    // Tomar el primer Catalog y el primer Pages como plantilla; el resto de
    // páginas se reparentan a ese único nodo Pages.
    let mut catalog_object: Option<(ObjectId, Object)> = None;
    let mut pages_object: Option<(ObjectId, Object)> = None;

    for (object_id, object) in &documents_objects {
        match object.type_name().unwrap_or("") {
            "Catalog" => {
                if catalog_object.is_none() {
                    catalog_object = Some((*object_id, object.clone()));
                }
            }
            "Pages" => {
                if pages_object.is_none() {
                    pages_object = Some((*object_id, object.clone()));
                }
            }
            "Page" | "Outlines" | "Outline" => {} // páginas: vía documents_pages
            _ => {
                document.objects.insert(*object_id, object.clone());
            }
        }
    }

    let Some(catalog_object) = catalog_object else {
        return Err(PdfError::InvalidPdf(
            "ningún Catalog en los PDFs de entrada".into(),
        ));
    };
    let Some(pages_object) = pages_object else {
        return Err(PdfError::InvalidPdf(
            "ningún Pages en los PDFs de entrada".into(),
        ));
    };

    // Reparentar y copiar cada página al documento destino.
    for (object_id, object) in &documents_pages {
        if let Ok(dict) = object.as_dict() {
            let mut dict = dict.clone();
            dict.set("Parent", pages_object.0);
            document
                .objects
                .insert(*object_id, Object::Dictionary(dict));
        }
    }

    // Reconstruir el nodo Pages con todos los kids y el Count total.
    if let Ok(dict) = pages_object.1.as_dict() {
        let mut dict = dict.clone();
        dict.set("Count", documents_pages.len() as u32);
        dict.set(
            "Kids",
            documents_pages
                .keys()
                .map(|id| Object::Reference(*id))
                .collect::<Vec<_>>(),
        );
        document
            .objects
            .insert(pages_object.0, Object::Dictionary(dict));
    }

    // Catalog → Pages.
    if let Ok(dict) = catalog_object.1.as_dict() {
        let mut dict = dict.clone();
        dict.set("Pages", pages_object.0);
        dict.remove(b"Outlines");
        document
            .objects
            .insert(catalog_object.0, Object::Dictionary(dict));
    }

    document.trailer.set("Root", catalog_object.0);
    document.max_id = document.objects.len() as u32;
    document.renumber_objects();
    document.compress();
    document
        .save(output)
        .map_err(|e| PdfError::InvalidPdf(e.to_string()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use lopdf::{dictionary, Stream};

    fn tmp_dir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("merge-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Construye un PDF válido de `pages` páginas vacías.
    fn make_pdf(path: &Path, pages: u32) {
        let mut doc = Document::with_version("1.5");
        let pages_id = doc.new_object_id();
        let mut kids = Vec::new();
        for _ in 0..pages {
            let content = doc.add_object(Stream::new(dictionary! {}, b"".to_vec()));
            let page_id = doc.add_object(dictionary! {
                "Type" => "Page",
                "Parent" => pages_id,
                "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
                "Contents" => content,
            });
            kids.push(page_id.into());
        }
        let count = kids.len() as i64;
        let pages_dict = dictionary! {
            "Type" => "Pages",
            "Kids" => kids,
            "Count" => count,
        };
        doc.objects.insert(pages_id, Object::Dictionary(pages_dict));
        let catalog = doc.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
        });
        doc.trailer.set("Root", catalog);
        doc.save(path).unwrap();
    }

    #[test]
    fn merge_preserves_total_page_count() {
        let dir = tmp_dir();
        let a = dir.join("a.pdf");
        let b = dir.join("b.pdf");
        make_pdf(&a, 2);
        make_pdf(&b, 3);
        let out = dir.join("merged.pdf");

        merge(&[a, b], &out, &CancelToken::new()).unwrap();

        assert_eq!(crate::pdf::page_count(&out).unwrap(), 5);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn merge_cancelled_returns_error() {
        let dir = tmp_dir();
        let a = dir.join("a.pdf");
        make_pdf(&a, 1);
        let token = CancelToken::new();
        token.cancel();

        let err = merge(&[a], &dir.join("o.pdf"), &token).unwrap_err();
        assert!(matches!(err, PdfError::Cancelled));
        std::fs::remove_dir_all(&dir).ok();
    }
}

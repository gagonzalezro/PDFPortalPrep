use crate::error::PdfError;
use std::path::Path;

/// Cuenta las páginas de un PDF. Reemplaza el `PDFDocument.pageCount` de PDFKit.
pub fn page_count(path: &Path) -> Result<u32, PdfError> {
    let doc = lopdf::Document::load(path).map_err(|e| PdfError::InvalidPdf(e.to_string()))?;
    Ok(doc.get_pages().len() as u32)
}

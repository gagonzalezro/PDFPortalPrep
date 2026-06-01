use thiserror::Error;

/// Errores estructurados del core. Reemplaza los `NSError` por dominio/código
/// de la implementación Swift por un enum tipado.
#[derive(Debug, Error)]
pub enum PdfError {
    #[error("operación cancelada")]
    Cancelled,

    #[error("no se encontró Ghostscript en el sistema")]
    GhostscriptNotFound,

    #[error("Ghostscript falló: {0}")]
    Ghostscript(String),

    #[error("no se proporcionaron archivos de entrada")]
    NoInput,

    #[error("conteo de páginas inválido: se esperaban {expected}, se obtuvieron {actual}")]
    PageCountMismatch { expected: u32, actual: u32 },

    #[error("PDF inválido o dañado: {0}")]
    InvalidPdf(String),

    #[error("funcionalidad no implementada todavía: {0}")]
    NotImplemented(String),

    #[error("error de E/S: {0}")]
    Io(#[from] std::io::Error),
}

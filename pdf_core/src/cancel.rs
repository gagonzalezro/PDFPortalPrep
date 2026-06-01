use crate::error::PdfError;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Token de cancelación thread-safe y clonable.
/// Espejo del `NSLock` + `cancelled` de `PDFCompressionService`.
#[derive(Clone, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    pub fn new() -> Self {
        Self(Arc::new(AtomicBool::new(false)))
    }

    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    /// Devuelve `Err(Cancelled)` si se ha pedido cancelar.
    pub fn check(&self) -> Result<(), PdfError> {
        if self.is_cancelled() {
            Err(PdfError::Cancelled)
        } else {
            Ok(())
        }
    }
}

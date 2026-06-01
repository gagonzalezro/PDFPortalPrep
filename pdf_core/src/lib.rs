//! pdf_core — núcleo portable de procesamiento PDF para PDFPortalPrep.
//!
//! Espejo en Rust de la lógica de `Services/PDFProcessingService.swift`,
//! `PDFCompressionService.swift`, `PDFMergeService.swift` y
//! `PDFValidationService.swift` de la app SwiftUI original.

pub mod cancel;
pub mod compress;
pub mod error;
pub mod ghostscript;
pub mod merge;
pub mod models;
pub mod pdf;
pub mod validate;

pub use cancel::CancelToken;
pub use compress::process;
pub use error::PdfError;
pub use merge::merge;
pub use models::{Action, CompressionPreset, ProcessOutcome, ProcessRequest, Progress, ScanResult};
pub use validate::scan;

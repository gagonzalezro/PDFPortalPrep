//! pdf_core — núcleo portable de procesamiento PDF para PDFPortalPrep.
//!
//! Espejo en Rust de la lógica de `Services/PDFProcessingService.swift` y
//! `Services/PDFCompressionService.swift` de la app SwiftUI original.
//! Fase 1: compresión de un solo PDF (escalera DPI + guard output ≤ input).
//! Merge y validación interactiva/cifrado llegan en Fase 2.

pub mod compress;
pub mod error;
pub mod ghostscript;
pub mod models;
pub mod pdf;

pub use compress::process;
pub use error::PdfError;
pub use models::{Action, CompressionPreset, ProcessOutcome, ProcessRequest, Progress};

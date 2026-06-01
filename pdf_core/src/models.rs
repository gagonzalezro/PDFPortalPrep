use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Perfil de compresión. Espejo de `Models/CompressionPreset.swift`.
/// La escalera DPI y la calidad JPEG son el contrato congelado que la app
/// nueva debe igualar bit a bit con la SwiftUI original.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompressionPreset {
    Light,
    Balanced,
    Maximum,
}

impl CompressionPreset {
    /// DPI probados de mayor (más calidad) a menor (más compresión).
    pub fn dpi_ladder(self) -> &'static [u32] {
        match self {
            CompressionPreset::Light => &[220, 180, 150],
            CompressionPreset::Balanced => &[150, 130, 110],
            CompressionPreset::Maximum => &[110, 90, 72],
        }
    }

    /// DPI mínimo permitido para el perfil (último peldaño de la escalera).
    pub fn floor_dpi(self) -> u32 {
        *self.dpi_ladder().last().expect("la escalera nunca está vacía")
    }

    /// Calidad JPEG en rango 0..=1 (se multiplica ×100 al pasar a Ghostscript).
    pub fn jpeg_quality(self) -> f64 {
        match self {
            CompressionPreset::Light => 0.85,
            CompressionPreset::Balanced => 0.72,
            CompressionPreset::Maximum => 0.55,
        }
    }

    /// El perfil Máximo siempre avisa de posible pérdida de nitidez.
    pub fn always_warns_about_quality(self) -> bool {
        matches!(self, CompressionPreset::Maximum)
    }
}

/// Acción a ejecutar. Espejo de `PDFProcessingService.Action`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    CompressSingle,
    MergeAndCompress,
}

/// Petición de procesamiento. Espejo de `PDFProcessingService.Request`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessRequest {
    pub input_paths: Vec<PathBuf>,
    pub action: Action,
    pub preset: CompressionPreset,
    pub target_bytes: u64,
    pub output_dir: PathBuf,
    pub base_name: String,
    pub original_total_size: u64,
    pub expected_page_count: u32,
}

/// Resultado del procesamiento. Espejo de `PDFProcessingService.Outcome`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessOutcome {
    pub output_path: PathBuf,
    pub final_size: u64,
    pub original_size: u64,
    pub page_count: u32,
    pub expected_page_count: u32,
    pub reduction_percentage: f64,
    /// `None` cuando se conservó el original sin recomprimir.
    pub applied_dpi: Option<u32>,
    pub kept_original: bool,
    pub hit_floor_without_meeting: bool,
    pub meets_limit: bool,
    pub engine_label: String,
}

/// Estados de progreso emitidos durante el procesamiento.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Progress {
    Merging,
    TryingDpi(u32),
    Finalizing,
}

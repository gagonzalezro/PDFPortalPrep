//! Smoke test manual del camino real con Ghostscript.
//! Uso: cargo run --example smoke -- <input.pdf> <target_mb>
//! No forma parte de `cargo test` (es un example), así que no rompe CI.

use pdf_core::{process, Action, CompressionPreset, ProcessRequest};
use std::path::PathBuf;

fn main() {
    let mut args = std::env::args().skip(1);
    let input = PathBuf::from(args.next().expect("falta <input.pdf>"));
    let target_mb: f64 = args
        .next()
        .unwrap_or_else(|| "0.5".into())
        .parse()
        .expect("target_mb inválido");

    let original_size = std::fs::metadata(&input).expect("input no existe").len();
    let expected_pages = pdf_core::pdf::page_count(&input).expect("no se pudo leer el PDF");
    let out_dir = std::env::temp_dir();

    let req = ProcessRequest {
        input_paths: vec![input.clone()],
        action: Action::CompressSingle,
        preset: CompressionPreset::Balanced,
        target_bytes: (target_mb * 1024.0 * 1024.0) as u64,
        output_dir: out_dir,
        base_name: "smoke-output".into(),
        original_total_size: original_size,
        expected_page_count: expected_pages,
    };

    println!(
        "input: {} bytes, {} páginas, target {:.2} MB",
        original_size, expected_pages, target_mb
    );

    match process(&req, |p| println!("  progreso: {:?}", p)) {
        Ok(o) => {
            println!("--- OUTCOME ---");
            println!("output:        {}", o.output_path.display());
            println!("final_size:    {} bytes", o.final_size);
            println!("original_size: {} bytes", o.original_size);
            println!("reducción:     {:.1}%", o.reduction_percentage);
            println!("páginas:       {} (esperadas {})", o.page_count, o.expected_page_count);
            println!("applied_dpi:   {:?}", o.applied_dpi);
            println!("kept_original: {}", o.kept_original);
            println!("hit_floor:     {}", o.hit_floor_without_meeting);
            println!("meets_limit:   {}", o.meets_limit);
            println!("engine:        {}", o.engine_label);
            assert!(o.final_size <= o.original_size, "GUARD VIOLADO: output > input");
            assert_eq!(o.page_count, o.expected_page_count, "PÁGINAS NO PRESERVADAS");
            println!("✅ invariantes OK (output ≤ input, páginas preservadas)");
        }
        Err(e) => {
            eprintln!("❌ error: {e}");
            std::process::exit(1);
        }
    }
}

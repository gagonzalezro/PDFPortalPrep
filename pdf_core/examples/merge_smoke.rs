//! Smoke test manual de merge + compresión con Ghostscript real.
//! Uso: cargo run --example merge_smoke -- <target_mb> <a.pdf> <b.pdf> [c.pdf ...]

use pdf_core::{process, scan, Action, CancelToken, CompressionPreset, ProcessRequest};
use std::path::PathBuf;

fn main() {
    let mut args = std::env::args().skip(1);
    let target_mb: f64 = args.next().expect("falta <target_mb>").parse().expect("target_mb inválido");
    let inputs: Vec<PathBuf> = args.map(PathBuf::from).collect();
    assert!(inputs.len() >= 2, "pasa al menos 2 PDFs");

    let mut original_total = 0u64;
    let mut expected_pages = 0u32;
    for p in &inputs {
        let s = scan(p);
        println!("entrada: {} — {} bytes, {} págs, válido={}", p.display(), s.file_size, s.page_count, s.is_valid);
        original_total += s.file_size;
        expected_pages += s.page_count;
    }

    let req = ProcessRequest {
        input_paths: inputs.clone(),
        action: Action::MergeAndCompress,
        preset: CompressionPreset::Balanced,
        target_bytes: (target_mb * 1024.0 * 1024.0) as u64,
        output_dir: std::env::temp_dir(),
        base_name: "merge-smoke-output".into(),
        original_total_size: original_total,
        expected_page_count: expected_pages,
    };

    println!("--> merge+compress de {} PDFs, target {:.2} MB, {} págs esperadas", inputs.len(), target_mb, expected_pages);

    match process(&req, &CancelToken::new(), |p| println!("  progreso: {:?}", p)) {
        Ok(o) => {
            println!("output:        {}", o.output_path.display());
            println!("{} → {} bytes ({:.1}% menos)", o.original_size, o.final_size, o.reduction_percentage);
            println!("páginas:       {} (esperadas {})", o.page_count, o.expected_page_count);
            println!("applied_dpi:   {:?} · meets_limit: {}", o.applied_dpi, o.meets_limit);
            assert_eq!(o.page_count, o.expected_page_count, "PÁGINAS NO PRESERVADAS EN EL MERGE");
            assert!(o.final_size <= o.original_size, "GUARD VIOLADO");
            println!("✅ merge preserva páginas y output ≤ suma de entradas");
        }
        Err(e) => {
            eprintln!("❌ error: {e}");
            std::process::exit(1);
        }
    }
}

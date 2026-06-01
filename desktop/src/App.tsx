import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import "./App.css";

type ScanResult = {
  path: string;
  fileSize: number;
  pageCount: number;
  isValid: boolean;
};

type ProcessOutcome = {
  outputPath: string;
  finalSize: number;
  originalSize: number;
  pageCount: number;
  expectedPageCount: number;
  reductionPercentage: number;
  appliedDpi: number | null;
  keptOriginal: boolean;
  hitFloorWithoutMeeting: boolean;
  meetsLimit: boolean;
  engineLabel: string;
};

const MB = 1024 * 1024;

function fmtBytes(b: number): string {
  if (b < 1024) return `${b} B`;
  if (b < MB) return `${(b / 1024).toFixed(1)} KB`;
  return `${(b / MB).toFixed(2)} MB`;
}

function parentDir(p: string): string {
  const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"));
  return i > 0 ? p.slice(0, i) : ".";
}

function stem(p: string): string {
  const name = p.split(/[/\\]/).pop() ?? p;
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(0, dot) : name;
}

function App() {
  const [scan, setScan] = useState<ScanResult | null>(null);
  const [targetMb, setTargetMb] = useState(5);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState("");
  const [outcome, setOutcome] = useState<ProcessOutcome | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    const un = listen<{ tryingDpi?: number } | string>("compress-progress", (e) => {
      const p = e.payload as any;
      if (p === "merging") setProgress("Uniendo…");
      else if (p === "finalizing") setProgress("Finalizando…");
      else if (p && p.tryingDpi) setProgress(`Probando ${p.tryingDpi} DPI…`);
    });
    return () => {
      un.then((f) => f());
    };
  }, []);

  async function pickFile() {
    setError("");
    setOutcome(null);
    const selected = await open({
      multiple: false,
      filters: [{ name: "PDF", extensions: ["pdf"] }],
    });
    if (typeof selected !== "string") return;
    try {
      const r = await invoke<ScanResult>("scan_pdf", { path: selected });
      if (!r.isValid) {
        setError("El archivo no es un PDF válido o está dañado.");
        setScan(null);
        return;
      }
      setScan(r);
    } catch (e) {
      setError(String(e));
    }
  }

  async function compress() {
    if (!scan) return;
    setBusy(true);
    setError("");
    setOutcome(null);
    setProgress("Iniciando…");
    try {
      const request = {
        inputPaths: [scan.path],
        action: "compressSingle",
        preset: "balanced",
        targetBytes: Math.round(targetMb * MB),
        outputDir: parentDir(scan.path),
        baseName: `${stem(scan.path)}-comprimido`,
        originalTotalSize: scan.fileSize,
        expectedPageCount: scan.pageCount,
      };
      const o = await invoke<ProcessOutcome>("process_pdfs", { request });
      setOutcome(o);
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
      setProgress("");
    }
  }

  return (
    <main className="container">
      <h1>PDF Portal Prep</h1>
      <p className="subtitle">Comprime un PDF localmente (Tauri + Rust + Ghostscript)</p>

      <div className="card">
        <button onClick={pickFile} disabled={busy}>
          Elegir PDF…
        </button>
        {scan && (
          <div className="meta">
            <div>{scan.path.split(/[/\\]/).pop()}</div>
            <div>
              {fmtBytes(scan.fileSize)} · {scan.pageCount} páginas
            </div>
          </div>
        )}
      </div>

      {scan && (
        <div className="card">
          <label>
            Límite objetivo: <strong>{targetMb} MB</strong>
            <input
              type="range"
              min={0.5}
              max={25}
              step={0.5}
              value={targetMb}
              onChange={(e) => setTargetMb(parseFloat(e.target.value))}
              disabled={busy}
            />
          </label>
          <button className="primary" onClick={compress} disabled={busy}>
            {busy ? "Procesando…" : `Crear PDF menor de ${targetMb} MB`}
          </button>
          {busy && <div className="progress">{progress}</div>}
        </div>
      )}

      {error && <div className="card error">⚠️ {error}</div>}

      {outcome && (
        <div className="card result">
          <h2>{outcome.meetsLimit ? "✅ Listo" : "⚠️ Comprimido, pero sobre el límite"}</h2>
          <div>
            {fmtBytes(outcome.originalSize)} → <strong>{fmtBytes(outcome.finalSize)}</strong>{" "}
            ({outcome.reductionPercentage.toFixed(1)}% menos)
          </div>
          <div>
            Páginas: {outcome.pageCount} / {outcome.expectedPageCount} preservadas
          </div>
          <div className="muted">
            {outcome.keptOriginal
              ? "Sin recompresión (el original ya era óptimo)"
              : `Aplicado ${outcome.appliedDpi} DPI · ${outcome.engineLabel}`}
          </div>
          {outcome.hitFloorWithoutMeeting && (
            <div className="warn">
              Se alcanzó el límite de calidad del perfil sin llegar al objetivo. Prueba el perfil Máximo.
            </div>
          )}
          <div className="muted small">{outcome.outputPath}</div>
        </div>
      )}
    </main>
  );
}

export default App;

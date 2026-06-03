import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import "./App.css";

type ActionType = "compressSingle" | "mergeAndCompress";
type CompressionPreset = "light" | "balanced" | "maximum";

type ScanResult = {
  path: string;
  fileSize: number;
  pageCount: number;
  isValid: boolean;
  isEncrypted: boolean;
  hasInteractiveElements: boolean;
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

type GmailConnectedAccount = {
  email: string;
};

type GmailAttachmentResult = {
  id: string;
  accountEmail: string;
  messageId: string;
  attachmentId: string;
  filename: string;
  size: number;
  subject: string;
  from: string;
  date: string;
};

type GmailSearchResult = {
  scannedMessageCount: number;
  attachments: GmailAttachmentResult[];
  reachedLimit: boolean;
};

type PdfInputFile = ScanResult & {
  id: string;
  name: string;
};

type CompressionPresetOption = {
  value: CompressionPreset;
  label: string;
  shortLabel: string;
  alwaysWarnsAboutQuality: boolean;
};

const PRESETS: CompressionPresetOption[] = [
  {
    value: "light",
    label: "Ligera - maxima legibilidad e imagenes",
    shortLabel: "Ligera",
    alwaysWarnsAboutQuality: false,
  },
  {
    value: "balanced",
    label: "Balanceada - recomendada para email/subidas",
    shortLabel: "Balanceada",
    alwaysWarnsAboutQuality: false,
  },
  {
    value: "maximum",
    label: "Maxima - reduccion agresiva (puede afectar la calidad)",
    shortLabel: "Maxima",
    alwaysWarnsAboutQuality: true,
  },
];

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

function qualityImpactLabel(appliedDpi: number | null): string {
  if (appliedDpi == null) return "Sin recompresion (no se modificaron las imagenes)";
  if (appliedDpi >= 150) return "Impacto visual estimado: bajo";
  if (appliedDpi >= 110) return "Impacto visual estimado: medio";
  return "Impacto visual estimado: alto";
}

function uniqueByPath(items: PdfInputFile[]): PdfInputFile[] {
  const seen = new Set<string>();
  return items.filter((item) => {
    if (seen.has(item.path)) return false;
    seen.add(item.path);
    return true;
  });
}

function App() {
  const [files, setFiles] = useState<PdfInputFile[]>([]);
  const [targetMb, setTargetMb] = useState(5);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState("");
  const [outcome, setOutcome] = useState<ProcessOutcome | null>(null);
  const [error, setError] = useState("");
  const [actionType, setActionType] = useState<ActionType>("mergeAndCompress");
  const [selectedPreset, setSelectedPreset] = useState<CompressionPreset>("balanced");
  const [qualityWarning, setQualityWarning] = useState("");
  const [logPath, setLogPath] = useState("");
  const [gmailAccounts, setGmailAccounts] = useState<GmailConnectedAccount[]>([]);
  const [selectedGmailAccountEmails, setSelectedGmailAccountEmails] = useState<string[]>([]);
  const [gmailQuery, setGmailQuery] = useState("");
  const [gmailFrom, setGmailFrom] = useState("");
  const [gmailAfter, setGmailAfter] = useState("");
  const [gmailBefore, setGmailBefore] = useState("");
  const [gmailResults, setGmailResults] = useState<GmailAttachmentResult[]>([]);
  const [selectedGmailAttachmentIds, setSelectedGmailAttachmentIds] = useState<string[]>([]);
  const [isGmailWorking, setIsGmailWorking] = useState(false);
  const [gmailStatusText, setGmailStatusText] = useState("");
  const jobIdRef = useRef<string>("");

  const selectedPresetMeta = PRESETS.find((preset) => preset.value === selectedPreset) ?? PRESETS[1];
  const totalSize = files.reduce((sum, file) => sum + file.fileSize, 0);
  const totalPages = files.reduce((sum, file) => sum + file.pageCount, 0);
  const hasEncryptedFiles = files.some((file) => file.isEncrypted);
  const hasInteractiveFiles = files.some((file) => file.hasInteractiveElements);

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

  useEffect(() => {
    void refreshGmailAccounts();
  }, []);

  async function scanPaths(paths: string[]) {
    const scans = await Promise.all(
      paths.map(async (path) => {
        const scan = await invoke<ScanResult>("scan_pdf", { path });
        return {
          ...scan,
          id: crypto.randomUUID(),
          name: path.split(/[/\\]/).pop() ?? path,
        } satisfies PdfInputFile;
      }),
    );

    const invalid = scans.find((scan) => !scan.isValid);
    if (invalid) {
      throw new Error(`El archivo ${invalid.name} no es un PDF valido o esta dañado.`);
    }

    setFiles((current) => uniqueByPath([...current, ...scans]));
  }

  async function pickFiles() {
    setError("");
    setOutcome(null);
    setQualityWarning("");
    setLogPath("");

    const selected = await open({
      multiple: true,
      filters: [{ name: "PDF", extensions: ["pdf"] }],
    });

    const paths = Array.isArray(selected) ? selected : selected ? [selected] : [];
    if (paths.length === 0) return;

    try {
      await scanPaths(paths);
    } catch (e) {
      setError(String(e));
    }
  }

  async function refreshGmailAccounts() {
    try {
      const accounts = await invoke<GmailConnectedAccount[]>("gmail_connected_accounts");
      setGmailAccounts(accounts);
      setSelectedGmailAccountEmails((current) => {
        const allowed = new Set(accounts.map((account) => account.email));
        const filtered = current.filter((email) => allowed.has(email));
        return filtered.length > 0 ? filtered : accounts.map((account) => account.email);
      });
    } catch (e) {
      setGmailStatusText(String(e));
    }
  }

  async function connectGmail() {
    setIsGmailWorking(true);
    setGmailStatusText("Abriendo el navegador para autorizar con Google...");
    try {
      const account = await invoke<GmailConnectedAccount>("gmail_connect");
      await refreshGmailAccounts();
      setSelectedGmailAccountEmails((current) => {
        const next = new Set(current);
        next.add(account.email);
        return [...next];
      });
      setGmailStatusText(`Gmail conectado: ${account.email}.`);
    } catch (e) {
      setGmailStatusText(String(e));
    } finally {
      setIsGmailWorking(false);
    }
  }

  async function disconnectGmail(accountEmail: string) {
    setIsGmailWorking(true);
    try {
      await invoke("gmail_disconnect", { accountEmail });
      await refreshGmailAccounts();
      setGmailResults([]);
      setSelectedGmailAttachmentIds([]);
      setGmailStatusText(`Gmail desconectado: ${accountEmail}.`);
    } catch (e) {
      setGmailStatusText(String(e));
    } finally {
      setIsGmailWorking(false);
    }
  }

  async function searchGmail() {
    if (selectedGmailAccountEmails.length === 0) {
      setGmailStatusText("Selecciona al menos una cuenta Gmail para buscar.");
      return;
    }

    setIsGmailWorking(true);
    setGmailStatusText("Buscando en Gmail...");
    try {
      const result = await invoke<GmailSearchResult>("gmail_search", {
        filters: {
          text: gmailQuery,
          from: gmailFrom,
          after: gmailAfter,
          before: gmailBefore,
        },
        accountEmails: selectedGmailAccountEmails,
      });
      setGmailResults(result.attachments);
      setSelectedGmailAttachmentIds([]);
      setGmailStatusText(
        result.attachments.length === 0
          ? `Escaneados ${result.scannedMessageCount} mensaje(s). Sin PDFs encontrados.${result.reachedLimit ? " Se alcanzo el limite de 500 mensajes." : ""}`
          : `Escaneados ${result.scannedMessageCount} mensaje(s). ${result.attachments.length} PDF(s) encontrados.${result.reachedLimit ? " Se alcanzo el limite de 500 mensajes." : ""}`,
      );
    } catch (e) {
      setGmailStatusText(String(e));
    } finally {
      setIsGmailWorking(false);
    }
  }

  async function downloadSelectedGmailAttachments() {
    const selected = gmailResults.filter((attachment) => selectedGmailAttachmentIds.includes(attachment.id));
    if (selected.length === 0) {
      setGmailStatusText("Selecciona al menos un PDF de Gmail.");
      return;
    }

    setIsGmailWorking(true);
    setGmailStatusText(`Descargando ${selected.length} PDF(s)...`);
    try {
      const paths = await invoke<string[]>("gmail_download", { attachments: selected });
      await scanPaths(paths);
      setGmailStatusText(`${paths.length} PDF(s) descargados y añadidos.`);
    } catch (e) {
      setGmailStatusText(String(e));
    } finally {
      setIsGmailWorking(false);
    }
  }

  function toggleGmailAccount(email: string) {
    setSelectedGmailAccountEmails((current) =>
      current.includes(email) ? current.filter((value) => value !== email) : [...current, email],
    );
  }

  function toggleGmailAttachment(id: string) {
    setSelectedGmailAttachmentIds((current) =>
      current.includes(id) ? current.filter((value) => value !== id) : [...current, id],
    );
  }

  function removeFile(id: string) {
    setFiles((current) => current.filter((file) => file.id !== id));
  }

  function moveFile(id: string, direction: -1 | 1) {
    setFiles((current) => {
      const index = current.findIndex((file) => file.id === id);
      const nextIndex = index + direction;
      if (index < 0 || nextIndex < 0 || nextIndex >= current.length) return current;
      const next = [...current];
      [next[index], next[nextIndex]] = [next[nextIndex], next[index]];
      return next;
    });
  }

  async function writeProcessLog(nextOutcome: ProcessOutcome, compressionLevel: string) {
    try {
      const path = await invoke<string>("write_process_log", {
        outputPath: nextOutcome.outputPath,
        originalSize: nextOutcome.originalSize,
        finalSize: nextOutcome.finalSize,
        pageCount: nextOutcome.pageCount,
        compressionLevel,
        meetsLimit: nextOutcome.meetsLimit,
      });
      setLogPath(path);
    } catch {
      setLogPath("");
    }
  }

  async function compress() {
    if (files.length === 0) return;
    if (actionType === "compressSingle" && files.length !== 1) {
      setError("La accion 'Comprimir un PDF' requiere exactamente un documento.");
      return;
    }

    setBusy(true);
    setError("");
    setOutcome(null);
    setQualityWarning("");
    setLogPath("");
    setProgress("Iniciando…");
    const jobId = crypto.randomUUID();
    jobIdRef.current = jobId;

    try {
      const originalSize = totalSize;
      const expectedPageCount = totalPages;
      const firstPath = files[0]?.path ?? ".";

      const request = {
        inputPaths: files.map((file) => file.path),
        action: actionType,
        preset: selectedPreset,
        targetBytes: Math.round(targetMb * MB),
        outputDir: parentDir(firstPath),
        baseName:
          actionType === "mergeAndCompress"
            ? "Visa_Documents_Combined.pdf"
            : `${stem(firstPath)}-comprimido`,
        originalTotalSize: originalSize,
        expectedPageCount,
      };
      const o = await invoke<ProcessOutcome>("process_pdfs", { jobId, request });
      setOutcome(o);

      const levelLabel = o.keptOriginal
        ? "Sin recompresion"
        : o.appliedDpi != null
          ? `${selectedPresetMeta.shortLabel} (${o.appliedDpi} dpi)`
          : selectedPresetMeta.shortLabel;

      await writeProcessLog(o, levelLabel);

      if (o.keptOriginal && !o.meetsLimit) {
        setQualityWarning(
          `No se pudo bajar de ${targetMb.toFixed(1)} MB sin generar un archivo peor que el original. Se conservo el original.`,
        );
      } else if (o.hitFloorWithoutMeeting) {
        setQualityWarning(
          `Se alcanzo el limite de calidad del perfil ${selectedPresetMeta.shortLabel} sin bajar de ${targetMb.toFixed(1)} MB.`,
        );
      } else if (selectedPresetMeta.alwaysWarnsAboutQuality && !o.keptOriginal) {
        setQualityWarning(
          "Perfil Maxima: revisa el PDF porque la nitidez de texto escaneado e imagenes puede haberse reducido.",
        );
      }
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
      setProgress("");
    }
  }

  async function cancelJob() {
    if (jobIdRef.current) {
      await invoke("cancel_process", { jobId: jobIdRef.current });
    }
  }

  async function openResult() {
    if (!outcome) return;
    await invoke("open_path", { path: outcome.outputPath });
  }

  async function revealResult() {
    if (!outcome) return;
    await invoke("reveal_in_folder", { path: outcome.outputPath });
  }

  async function openLog() {
    if (!logPath) return;
    await invoke("open_path", { path: logPath });
  }

  return (
    <main className="container">
      <header className="hero">
        <div>
          <h1>PDF Portal Prep</h1>
          <p className="subtitle">Ruta Windows/macOS: Tauri + Rust + Ghostscript</p>
        </div>
        <div className="hero-stats">
          <span>{files.length} documento(s)</span>
          <span>{fmtBytes(totalSize)}</span>
          <span>{totalPages} paginas</span>
        </div>
      </header>

      <section className="layout">
        <div className="left-panel">
          <div className="card sidebar-card">
            <div className="sidebar-header">
              <div className="app-icon">PDF</div>
              <div>
                <h2 className="sidebar-title">PDF Portal Prep</h2>
                <p className="subtitle compact">Local &amp; Secure Document Optimization</p>
              </div>
            </div>

            <div className="dropzone-shell">
              <div className="dropzone-icon">+</div>
              <div className="dropzone-copy">Arrastra aqui tus documentos PDF</div>
              <div className="dropzone-subcopy">o</div>
              <button onClick={pickFiles} disabled={busy}>
                Seleccionar PDFs
              </button>
              <p className="helper">Puedes cargar uno o varios PDFs para comprimir o unir y comprimir.</p>
            </div>

            <div className="gmail-card">
              <div className="gmail-header">
                <h2>Importar PDFs desde Gmail</h2>
                <button onClick={connectGmail} disabled={isGmailWorking}>
                  {gmailAccounts.length > 0 ? "Conectar otra cuenta" : "Conectar con Google"}
                </button>
              </div>

              {gmailAccounts.length > 0 && (
                <div className="gmail-accounts">
                  {gmailAccounts.map((account) => (
                    <div key={account.email} className="gmail-account-row">
                      <label>
                        <input
                          type="checkbox"
                          checked={selectedGmailAccountEmails.includes(account.email)}
                          onChange={() => toggleGmailAccount(account.email)}
                          disabled={isGmailWorking}
                        />
                        <span>{account.email}</span>
                      </label>
                      <button onClick={() => disconnectGmail(account.email)} disabled={isGmailWorking}>
                        Desconectar
                      </button>
                    </div>
                  ))}
                </div>
              )}

              <div className="gmail-search-grid">
                <input
                  type="text"
                  placeholder="visa, payslip, bank statement"
                  value={gmailQuery}
                  onChange={(e) => setGmailQuery(e.target.value)}
                  disabled={isGmailWorking}
                />
                <input
                  type="text"
                  placeholder="from"
                  value={gmailFrom}
                  onChange={(e) => setGmailFrom(e.target.value)}
                  disabled={isGmailWorking}
                />
                <input
                  type="text"
                  placeholder="after yyyy-mm-dd"
                  value={gmailAfter}
                  onChange={(e) => setGmailAfter(e.target.value)}
                  disabled={isGmailWorking}
                />
                <input
                  type="text"
                  placeholder="before yyyy-mm-dd"
                  value={gmailBefore}
                  onChange={(e) => setGmailBefore(e.target.value)}
                  disabled={isGmailWorking}
                />
              </div>

              <div className="actions-row">
                <button onClick={searchGmail} disabled={isGmailWorking || gmailAccounts.length === 0}>
                  Buscar en Gmail
                </button>
                <button
                  onClick={downloadSelectedGmailAttachments}
                  disabled={isGmailWorking || selectedGmailAttachmentIds.length === 0}
                >
                  Descargar seleccionados ({selectedGmailAttachmentIds.length})
                </button>
              </div>

              {gmailResults.length > 0 && (
                <div className="gmail-results">
                  {gmailResults.map((result) => (
                    <label key={result.id} className="gmail-result-row">
                      <input
                        type="checkbox"
                        checked={selectedGmailAttachmentIds.includes(result.id)}
                        onChange={() => toggleGmailAttachment(result.id)}
                        disabled={isGmailWorking}
                      />
                      <div>
                        <div className="file-name">{result.filename}</div>
                        <div className="muted">{result.subject}</div>
                        <div className="muted small">
                          {result.from} · {fmtBytes(result.size)} · {result.accountEmail}
                        </div>
                      </div>
                    </label>
                  ))}
                </div>
              )}

              {gmailStatusText && <p className="gmail-status">{gmailStatusText}</p>}
            </div>

            <div className="control-group">
              <span className="label">Accion</span>
              <div className="segmented">
                <button
                  className={actionType === "compressSingle" ? "active" : ""}
                  onClick={() => setActionType("compressSingle")}
                  disabled={busy}
                >
                  Comprimir un PDF
                </button>
                <button
                  className={actionType === "mergeAndCompress" ? "active" : ""}
                  onClick={() => setActionType("mergeAndCompress")}
                  disabled={busy}
                >
                  Unir y comprimir
                </button>
              </div>
            </div>

            <div className="control-group">
              <label className="label" htmlFor="targetMb">
                Limite objetivo: <strong>{targetMb.toFixed(1)} MB</strong>
              </label>
              <input
                id="targetMb"
                type="range"
                min={1}
                max={50}
                step={0.5}
                value={targetMb}
                onChange={(e) => setTargetMb(parseFloat(e.target.value))}
                disabled={busy}
              />
            </div>

            <div className="control-group">
              <span className="label">Perfil</span>
              <div className="preset-list">
                {PRESETS.map((preset) => (
                  <label key={preset.value} className={`preset ${selectedPreset === preset.value ? "selected" : ""}`}>
                    <input
                      type="radio"
                      name="preset"
                      value={preset.value}
                      checked={selectedPreset === preset.value}
                      onChange={() => setSelectedPreset(preset.value)}
                      disabled={busy}
                    />
                    <span>{preset.label}</span>
                  </label>
                ))}
              </div>
            </div>

            {(hasEncryptedFiles || hasInteractiveFiles || selectedPresetMeta.alwaysWarnsAboutQuality) && (
              <div className="warn">
                {hasEncryptedFiles && <div>Hay archivos cifrados/protegidos. La compresion puede fallar.</div>}
                {hasInteractiveFiles && <div>Hay formularios o elementos interactivos. Podrian alterarse al recomprimir.</div>}
                {selectedPresetMeta.alwaysWarnsAboutQuality && (
                  <div>El perfil Maxima puede reducir la nitidez de texto escaneado e imagenes.</div>
                )}
              </div>
            )}

            <button className="primary" onClick={compress} disabled={busy || files.length === 0}>
              {busy ? "Procesando…" : `Crear PDF menor de ${targetMb.toFixed(1)} MB`}
            </button>
            {busy && (
              <div className="progress">
                <span>{progress}</span>
                <button className="cancel" onClick={cancelJob}>
                  Cancelar
                </button>
              </div>
            )}
            {actionType === "compressSingle" && files.length > 1 && (
              <p className="inline-note">Para comprimir un PDF, deja solo un documento en la lista.</p>
            )}
          </div>

          <div className="card">
            <h2>Documentos seleccionados</h2>
            {files.length === 0 ? (
              <p className="empty">No se han agregado archivos.</p>
            ) : (
              <div className="file-list">
                {files.map((file, index) => (
                  <div key={file.id} className="file-row">
                    <div>
                      <div className="file-name">{file.name}</div>
                      <div className="muted">
                        {file.pageCount} paginas · {fmtBytes(file.fileSize)}
                      </div>
                    </div>
                    <div className="row-actions">
                      <button onClick={() => moveFile(file.id, -1)} disabled={index === 0 || busy}>
                        Subir
                      </button>
                      <button onClick={() => moveFile(file.id, 1)} disabled={index === files.length - 1 || busy}>
                        Bajar
                      </button>
                      <button onClick={() => removeFile(file.id)} disabled={busy}>
                        Quitar
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>

        <div className="right-panel">
          {error && <div className="card error">{error}</div>}

          <div className="card result result-shell">
            <h2>Resultado</h2>
            {!outcome ? (
              <p className="empty">Los resultados apareceran aqui cuando termine el proceso.</p>
            ) : (
              <>
                <div className="result-grid">
                  <div>
                    <span className="label">Salida</span>
                    <div className="file-name">{outcome.outputPath.split(/[/\\]/).pop()}</div>
                  </div>
                  <div>
                    <span className="label">Tamano</span>
                    <div>
                      {fmtBytes(outcome.originalSize)} a <strong>{fmtBytes(outcome.finalSize)}</strong>
                    </div>
                  </div>
                  <div>
                    <span className="label">Paginas</span>
                    <div>
                      {outcome.pageCount} de {outcome.expectedPageCount} preservadas
                    </div>
                  </div>
                  <div>
                    <span className="label">Motor</span>
                    <div>{outcome.engineLabel}</div>
                  </div>
                </div>

                <div className="status-strip">
                  <span>{outcome.meetsLimit ? "Cumple el limite" : "Supera el limite"}</span>
                  <span>{outcome.reductionPercentage.toFixed(1)}% menos</span>
                  <span>{qualityImpactLabel(outcome.appliedDpi)}</span>
                </div>

                {qualityWarning && <div className="warn">{qualityWarning}</div>}

                <div className="actions-row">
                  <button onClick={openResult}>Abrir resultado</button>
                  <button onClick={revealResult}>Mostrar en carpeta</button>
                  {logPath && <button onClick={openLog}>Abrir registro</button>}
                </div>

                <div className="muted small">{outcome.outputPath}</div>
                {logPath && <div className="muted small">Registro: {logPath}</div>}
              </>
            )}
          </div>
        </div>
      </section>
    </main>
  );
}

export default App;

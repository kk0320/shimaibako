import {
  BarChart3,
  CheckCircle2,
  Copy,
  Database,
  FileText,
  FolderPlus,
  HelpCircle,
  Images,
  ListChecks,
  Play,
  RefreshCcw,
  ScanLine,
  ScanSearch,
  Search,
  Settings2,
  ShieldCheck,
  Square,
  Trash2,
  Wifi,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState, useTransition } from "react";

const API_PORT = import.meta.env.VITE_API_PORT || "8000";
const API_BASE = import.meta.env.VITE_API_BASE || `${window.location.protocol}//${window.location.hostname}:${API_PORT}`;
const APP_NAME = "しまい箱";
const APP_TAGLINE = "ローカルファースト写真検索";
const TOKEN_KEY = "shimaibakoSessionToken";

async function api(path, options = {}) {
  const token = sessionStorage.getItem(TOKEN_KEY);
  const response = await fetch(`${API_BASE}${path}`, {
    headers: {
      "Content-Type": "application/json",
      ...(token ? { "X-ShimaiBako-Token": token } : {}),
      ...(options.headers || {}),
    },
    ...options,
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(detail.detail || response.statusText);
  }
  return response.json();
}

async function publicApi(path, options = {}) {
  const response = await fetch(`${API_BASE}${path}`, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(detail.detail || response.statusText);
  }
  return response.json();
}

function thumbnailUrl(id, token) {
  const query = token ? `?token=${encodeURIComponent(token)}` : "";
  return `${API_BASE}/api/items/${id}/thumbnail${query}`;
}

function formatBytes(value) {
  if (!Number.isFinite(value)) return "-";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${size.toFixed(size >= 10 || unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function formatDate(value) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString("ja-JP", { dateStyle: "medium", timeStyle: "short" });
}

function sourceTypeLabel(type) {
  if (type === "icloud") return "iCloud写真";
  if (type === "onedrive") return "OneDrive写真";
  if (type === "sample") return "サンプル";
  return "任意フォルダ";
}

const categoryOptions = [
  ["receipt", "領収書"],
  ["business_card", "名刺"],
  ["whiteboard", "ホワイトボード"],
  ["signboard", "看板"],
  ["document_photo", "書類写真"],
  ["screenshot", "スクショ"],
  ["construction_board", "工事黒板"],
  ["travel_photo", "旅行写真"],
  ["family_photo", "家族写真"],
  ["misc", "その他"],
];

function categoryLabel(category) {
  const found = categoryOptions.find(([value]) => value === category);
  return found ? found[1] : category || "-";
}

function ocrEngineLabel(engine) {
  if (engine === "tesseract") return "実OCR (Tesseract)";
  if (engine === "test_asset_fallback") return "テスト用結果";
  if (engine === "sample_fallback") return "サンプル用結果";
  if (engine === "not_processed") return "未処理";
  return engine || "-";
}

function ocrLanguageLabel(language) {
  if (language === "jpn+eng") return "日本語+英語";
  if (language === "jpn") return "日本語";
  if (language === "eng") return "英語";
  return language || "-";
}

const emptyFilters = {
  q: "",
  source_id: "",
  date_from: "",
  date_to: "",
  media_type: "",
  extension: "",
  category: "",
  screenshot: false,
  duplicates: false,
  missing_thumbnail: false,
  has_error: false,
  ocr_status: "",
  ocr_error: false,
};

const defaultScanOptions = {
  max_items: "",
  exclude_dirs: ".git,node_modules,.venv,__pycache__,data/thumbnails",
  exclude_extensions: "",
  regenerate_thumbnails: false,
  hash_mode: "full",
};

function BrandLockup() {
  return (
    <div className="brand-lockup">
      <img className="app-logo" src="/icons/shimaibako-icon.svg" alt="" />
      <div>
        <p className="subtle">{APP_TAGLINE}</p>
        <h1>{APP_NAME}</h1>
      </div>
    </div>
  );
}

export default function App() {
  const [health, setHealth] = useState(null);
  const [token, setToken] = useState(() => sessionStorage.getItem(TOKEN_KEY) || "");
  const [view, setView] = useState("search");
  const [sources, setSources] = useState([]);
  const [stats, setStats] = useState(null);
  const [status, setStatus] = useState(null);
  const [ocrStatus, setOcrStatus] = useState(null);
  const [filters, setFilters] = useState(emptyFilters);
  const [results, setResults] = useState({ items: [], total: 0, limit: 60, offset: 0 });
  const [detailId, setDetailId] = useState(null);
  const [detail, setDetail] = useState(null);
  const [duplicates, setDuplicates] = useState([]);
  const [logs, setLogs] = useState(null);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [isPending, startTransition] = useTransition();

  const loadSources = useCallback(async () => {
    const data = await api("/api/sources");
    setSources(data.sources);
  }, []);

  const loadStats = useCallback(async () => {
    const data = await api("/api/stats");
    setStats(data);
  }, []);

  const loadStatus = useCallback(async () => {
    const data = await api("/api/scan/status");
    setStatus(data);
  }, []);

  const loadOcrStatus = useCallback(async () => {
    const data = await api("/api/ocr/status");
    setOcrStatus(data);
  }, []);

  const runSearch = useCallback(
    async (nextFilters = filters, nextOffset = 0) => {
      const params = new URLSearchParams();
      Object.entries(nextFilters).forEach(([key, value]) => {
        if (value !== "" && value !== false && value !== null && value !== undefined) params.set(key, value);
      });
      params.set("limit", "60");
      params.set("offset", String(nextOffset));
      const data = await api(`/api/search?${params.toString()}`);
      setResults(data);
    },
    [filters],
  );

  const safeAction = useCallback(async (fn, successText = "") => {
    setError("");
    try {
      await fn();
      if (successText) setMessage(successText);
    } catch (err) {
      setError(err.message || String(err));
    }
  }, []);

  const refreshAll = useCallback(async () => {
    await loadSources();
    await loadStats();
    await loadStatus();
    await loadOcrStatus();
    await runSearch(filters, results.offset);
  }, [filters, loadOcrStatus, loadSources, loadStats, loadStatus, results.offset, runSearch]);

  useEffect(() => {
    safeAction(async () => {
      const data = await publicApi("/api/health");
      setHealth(data);
    });
  }, [safeAction]);

  useEffect(() => {
    if (!health) return;
    if (health.auth_required && !token) return;
    safeAction(async () => {
      await loadSources();
      await loadStats();
      await loadStatus();
      await loadOcrStatus();
      await runSearch(emptyFilters, 0);
    });
  }, [health, token]);

  useEffect(() => {
    const timer = window.setInterval(() => {
      loadStatus().catch(() => {});
      loadOcrStatus().catch(() => {});
    }, 1500);
    return () => window.clearInterval(timer);
  }, [loadOcrStatus, loadStatus]);

  useEffect(() => {
    if (detailId == null) {
      setDetail(null);
      return;
    }
    safeAction(async () => {
      const data = await api(`/api/items/${detailId}`);
      setDetail(data.item);
    });
  }, [detailId, safeAction]);

  useEffect(() => {
    if (view !== "stats") return;
    safeAction(async () => {
      const data = await api("/api/duplicates");
      setDuplicates(data.groups);
    });
  }, [view, safeAction]);

  const navItems = [
    { id: "search", label: "検索", icon: Search },
    { id: "sources", label: "ソース", icon: FolderPlus },
    { id: "scan", label: "スキャン", icon: ScanSearch },
    { id: "ocr", label: "OCR", icon: FileText },
    { id: "stats", label: "統計", icon: BarChart3 },
    { id: "help", label: "ヘルプ", icon: HelpCircle },
  ];

  const handleLogin = async (pin) => {
    const data = await publicApi("/api/auth/login", { method: "POST", body: JSON.stringify({ pin }) });
    sessionStorage.setItem(TOKEN_KEY, data.token);
    setToken(data.token);
    setMessage("認証しました");
  };

  const handleLogout = () => {
    sessionStorage.removeItem(TOKEN_KEY);
    setToken("");
    setSources([]);
    setStats(null);
    setResults({ items: [], total: 0, limit: 60, offset: 0 });
    setMessage("セッションを終了しました");
  };

  if (!health) {
    return (
      <div className="app-shell">
        <header className="topbar">
          <BrandLockup />
        </header>
        <div className="empty-state">起動状態を確認しています...</div>
      </div>
    );
  }

  if (health.auth_required && !token) {
    return <AuthGate onLogin={handleLogin} error={error} setError={setError} accessMode={health.access_mode} />;
  }

  return (
    <div className="app-shell">
      <header className="topbar">
        <BrandLockup />
        <div className="top-actions">
          {health.auth_required && <button onClick={handleLogout}>ロック</button>}
          <button className="icon-button" onClick={() => safeAction(refreshAll, "更新しました")} aria-label="更新">
            <RefreshCcw size={20} />
          </button>
        </div>
      </header>

      {health.access_mode === "lan" && <LanWarning />}
      <SafetyStrip />

      {(message || error) && (
        <div className={`toast ${error ? "error" : ""}`}>
          <span>{error || message}</span>
          <button onClick={() => (error ? setError("") : setMessage(""))} aria-label="閉じる">
            <X size={16} />
          </button>
        </div>
      )}

      <main className="content">
        {view === "search" && (
          <SearchScreen
            filters={filters}
            setFilters={setFilters}
            sources={sources}
            results={results}
            isPending={isPending}
            onSearch={(nextFilters, offset = 0) => {
              startTransition(() => {
                safeAction(() => runSearch(nextFilters, offset));
              });
            }}
            onOpenDetail={setDetailId}
            token={token}
          />
        )}
        {view === "sources" && <SourcesScreen sources={sources} onRefresh={() => safeAction(refreshAll)} onMessage={setMessage} onError={setError} />}
        {view === "scan" && (
          <ScanScreen
            sources={sources}
            status={status}
            logs={logs}
            setLogs={setLogs}
            onRefresh={() => safeAction(refreshAll)}
            onMessage={setMessage}
            onError={setError}
          />
        )}
        {view === "ocr" && <OcrScreen sources={sources} status={ocrStatus} stats={stats} onRefresh={() => safeAction(refreshAll)} onMessage={setMessage} onError={setError} />}
        {view === "stats" && <StatsScreen stats={stats} duplicateGroups={duplicates} onOpenDetail={setDetailId} token={token} />}
        {view === "help" && <HelpScreen apiBase={API_BASE} stats={stats} accessMode={health.access_mode} />}
      </main>

      <nav className="bottom-nav" aria-label="主要ナビゲーション">
        {navItems.map((item) => {
          const Icon = item.icon;
          return (
            <button key={item.id} className={view === item.id ? "active" : ""} onClick={() => setView(item.id)}>
              <Icon size={20} />
              <span>{item.label}</span>
            </button>
          );
        })}
      </nav>

      <DetailModal item={detail} onClose={() => setDetailId(null)} onMessage={setMessage} token={token} />
    </div>
  );
}

function AuthGate({ onLogin, error, setError, accessMode }) {
  const [pin, setPin] = useState("");
  const [busy, setBusy] = useState(false);
  const submit = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      await onLogin(pin);
    } catch (err) {
      setError(err.message || String(err));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="app-shell auth-shell">
      <header className="topbar">
        <BrandLockup />
      </header>
      {accessMode === "lan" && <LanWarning />}
      <form className="auth-card" onSubmit={submit}>
        <ShieldCheck size={34} />
        <h2>PINを入力してください</h2>
        <p>LAN公開モードでは、同じWi-Fi内の第三者アクセスを防ぐためPIN認証が必要です。PINは起動時のPowerShell画面に表示されています。</p>
        <input value={pin} onChange={(event) => setPin(event.target.value)} inputMode="numeric" autoComplete="one-time-code" placeholder="PIN" autoFocus />
        {error && <p className="auth-error">{error}</p>}
        <button className="primary" type="submit" disabled={busy || !pin.trim()}>
          認証して開く
        </button>
      </form>
    </div>
  );
}

function LanWarning() {
  return (
    <div className="lan-warning">
      <Wifi size={18} />
      <span>LAN公開中です。同じWi-Fi内の端末からアクセスできる可能性があります。信頼できる家庭内ネットワークでのみ使用してください。</span>
    </div>
  );
}

function SafetyStrip() {
  return (
    <div className="safety-strip" aria-label="安全方針">
      <span>
        <ShieldCheck size={16} />
        外部送信なし
      </span>
      <span>読み取り専用</span>
      <span>削除・移動・リネームしません</span>
    </div>
  );
}

function SearchScreen({ filters, setFilters, sources, results, isPending, onSearch, onOpenDetail, token }) {
  const update = (patch) => {
    const next = { ...filters, ...patch };
    setFilters(next);
    return next;
  };

  const submit = (event) => {
    event.preventDefault();
    const currentQuery = event.currentTarget.querySelector("#query")?.value ?? filters.q;
    const next = { ...filters, q: currentQuery };
    setFilters(next);
    onSearch(next, 0);
  };

  const clear = () => {
    setFilters(emptyFilters);
    onSearch(emptyFilters, 0);
  };

  return (
    <section className="screen">
      <DemoIntro />
      <form className="search-panel" onSubmit={submit}>
        <label className="search-label" htmlFor="query">
          ファイル名・フォルダ名・OCR文字で検索
        </label>
        <div className="search-input-wrap">
          <Search size={22} />
          <input id="query" value={filters.q} onChange={(event) => update({ q: event.target.value })} placeholder="東京、領収書、看板、メモ、Tokyo..." autoComplete="off" />
          <button type="submit">検索</button>
        </div>

        <div className="chip-row" aria-label="よく使う条件">
          <ToggleChip active={filters.media_type === "image"} onClick={() => update({ media_type: filters.media_type === "image" ? "" : "image" })}>
            画像
          </ToggleChip>
          <ToggleChip active={filters.media_type === "video"} onClick={() => update({ media_type: filters.media_type === "video" ? "" : "video" })}>
            動画
          </ToggleChip>
          <ToggleChip active={filters.screenshot} onClick={() => update({ screenshot: !filters.screenshot })}>
            スクショ
          </ToggleChip>
          <ToggleChip active={filters.duplicates} onClick={() => update({ duplicates: !filters.duplicates })}>
            重複候補
          </ToggleChip>
          <ToggleChip active={filters.ocr_status === "done"} onClick={() => update({ ocr_status: filters.ocr_status === "done" ? "" : "done" })}>
            OCR済み
          </ToggleChip>
          <ToggleChip active={filters.ocr_status === "pending"} onClick={() => update({ ocr_status: filters.ocr_status === "pending" ? "" : "pending" })}>
            OCR未処理
          </ToggleChip>
          <ToggleChip active={filters.category === "receipt"} onClick={() => update({ category: filters.category === "receipt" ? "" : "receipt" })}>
            領収書
          </ToggleChip>
        </div>

        <details className="advanced-filters">
          <summary>
            <Settings2 size={18} />
            詳細条件
          </summary>
          <div className="filter-grid">
            <label>
              データソース
              <select value={filters.source_id} onChange={(event) => update({ source_id: event.target.value })}>
                <option value="">すべて</option>
                {sources.map((source) => (
                  <option key={source.id} value={source.id}>
                    {source.name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              拡張子
              <input value={filters.extension} onChange={(event) => update({ extension: event.target.value })} placeholder="jpg,png,heic" />
            </label>
            <label>
              日付開始
              <input type="date" value={filters.date_from} onChange={(event) => update({ date_from: event.target.value })} />
            </label>
            <label>
              日付終了
              <input type="date" value={filters.date_to} onChange={(event) => update({ date_to: event.target.value })} />
            </label>
            <label>
              OCR状態
              <select value={filters.ocr_status} onChange={(event) => update({ ocr_status: event.target.value })}>
                <option value="">指定なし</option>
                <option value="done">OCR済み</option>
                <option value="pending">OCR未処理</option>
                <option value="error">読取エラー</option>
                <option value="processing">OCR処理中</option>
              </select>
            </label>
            <label>
              推定カテゴリ
              <select value={filters.category} onChange={(event) => update({ category: event.target.value })}>
                <option value="">すべて</option>
                {categoryOptions.map(([value, label]) => (
                  <option key={value} value={value}>
                    {label}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <div className="toggle-grid">
            <label>
              <input type="checkbox" checked={filters.missing_thumbnail} onChange={(event) => update({ missing_thumbnail: event.target.checked })} />
              未サムネイル
            </label>
            <label>
              <input type="checkbox" checked={filters.has_error} onChange={(event) => update({ has_error: event.target.checked })} />
              スキャンエラー
            </label>
            <label>
              <input type="checkbox" checked={filters.ocr_error} onChange={(event) => update({ ocr_error: event.target.checked, ocr_status: event.target.checked ? "" : filters.ocr_status })} />
              読取エラー
            </label>
          </div>
        </details>

        <div className="form-actions">
          <button type="button" className="secondary" onClick={clear}>
            条件クリア
          </button>
          <button type="submit" className="primary">
            <Search size={18} />
            検索する
          </button>
        </div>
      </form>

      <div className="section-heading">
        <div>
          <h2>検索結果</h2>
          <p>{isPending ? "検索中..." : `${results.total}件`}</p>
        </div>
      </div>

      <ResultGrid items={results.items} onOpenDetail={onOpenDetail} token={token} />
      {results.total > results.offset + results.limit && (
        <button className="wide-button" onClick={() => onSearch(filters, results.offset + results.limit)}>
          次の結果を表示
        </button>
      )}
    </section>
  );
}

function DemoIntro() {
  return (
    <article className="demo-intro">
      <div>
        <p className="subtle">しまい箱でできること</p>
        <h2>iCloud/OneDriveもまとめて探せます</h2>
        <p>
          <span>フォルダを読み取り専用でスキャンします。</span>
          <span>OCRを開始した写真は文字でも検索できます。</span>
        </p>
      </div>
      <div className="demo-list">
        <span>写真は外部送信しません</span>
        <span>読み取り専用です</span>
        <span>削除・移動・リネームしません</span>
        <span>OCRで文字検索</span>
        <span>スマホで見る時はPINが必要です</span>
        <span>実写真はコピーで試す</span>
      </div>
    </article>
  );
}

function ToggleChip({ active, onClick, children }) {
  return (
    <button type="button" className={active ? "chip active" : "chip"} onClick={onClick}>
      {children}
    </button>
  );
}

function ResultGrid({ items, onOpenDetail, token }) {
  if (!items.length) {
    return (
      <div className="empty-state">
        <Images size={40} />
        <h3>該当する写真がありません</h3>
        <p>サンプルをスキャンするか、同期済み写真フォルダをデータソースに追加してください。</p>
      </div>
    );
  }
  return (
    <div className="result-grid">
      {items.map((item) => (
        <button key={item.id} className="result-card" onClick={() => onOpenDetail(item.id)}>
          <img src={thumbnailUrl(item.id, token)} alt="" loading="lazy" />
          <span className="source-pill">{item.source_name}</span>
          {item.ocr_status === "done" && <span className="ocr-pill">{item.ocr_engine === "tesseract" ? "実OCR" : "テスト"}</span>}
          <span className="category-pill">{categoryLabel(item.inferred_category)}</span>
          <span className="card-name">{item.file_name}</span>
          <span className="card-meta">
            {item.extension.toUpperCase()} ・ {formatBytes(item.size_bytes)}
          </span>
        </button>
      ))}
    </div>
  );
}

function SourcesScreen({ sources, onRefresh, onMessage, onError }) {
  const [detected, setDetected] = useState([]);
  const [form, setForm] = useState({ path: "", name: "", source_type: "folder" });

  const run = async (fn, message) => {
    onError("");
    try {
      await fn();
      if (message) onMessage(message);
      await onRefresh();
      const data = await api("/api/sources/detect", { method: "POST", body: "{}" });
      setDetected(data.candidates);
    } catch (err) {
      onError(err.message || String(err));
    }
  };

  useEffect(() => {
    run(async () => {
      const data = await api("/api/sources/detect", { method: "POST", body: "{}" });
      setDetected(data.candidates);
    });
  }, []);

  const addSource = async (source) => {
    await api("/api/sources", { method: "POST", body: JSON.stringify(source) });
  };

  return (
    <section className="screen">
      <div className="section-heading">
        <div>
          <h2>データソース</h2>
          <p>登録削除はDB上だけです。元フォルダや元ファイルは変更しません。</p>
        </div>
      </div>

      <div className="explain-grid">
        <InfoBox title="iCloud写真" text="iCloud for Windows でPCに同期された写真フォルダを読み取り専用でスキャンします。" />
        <InfoBox title="OneDrive写真" text="OneDriveの同期済みフォルダを対象にします。クラウドAPIには接続しません。" />
        <InfoBox title="任意フォルダ" text="外付けドライブや整理済みフォルダも追加できます。削除や移動はしません。" />
        <InfoBox title="実写真の試し方" text="元写真フォルダを直接登録せず、data\\real_test_photos などへコピーした小規模フォルダで、最大100〜300件に絞って試してください。" />
      </div>

      <div className="source-form">
        <label>
          フォルダパス
          <input value={form.path} onChange={(event) => setForm({ ...form, path: event.target.value })} placeholder="C:\\Users\\user\\Pictures" />
        </label>
        <div className="filter-grid two">
          <label>
            表示名
            <input value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} placeholder="任意フォルダ" />
          </label>
          <label>
            種類
            <select value={form.source_type} onChange={(event) => setForm({ ...form, source_type: event.target.value })}>
              <option value="folder">任意フォルダ</option>
              <option value="icloud">iCloud写真</option>
              <option value="onedrive">OneDrive写真</option>
              <option value="sample">サンプル</option>
            </select>
          </label>
        </div>
        <button className="primary wide-button" onClick={() => run(() => addSource(form), "データソースを追加しました")}>
          <FolderPlus size={18} />
          フォルダを追加
        </button>
      </div>

      <div className="section-heading compact">
        <h3>自動検出候補</h3>
        <button className="secondary small" onClick={() => run(async () => {}, "候補を更新しました")}>
          <RefreshCcw size={16} />
          更新
        </button>
      </div>

      <div className="candidate-list">
        {detected.map((candidate) => (
          <div className="candidate-row" key={`${candidate.source_type}-${candidate.path}`}>
            <div>
              <strong>{candidate.name}</strong>
              <span>{sourceTypeLabel(candidate.source_type)}</span>
              <p>{candidate.path}</p>
            </div>
            <button disabled={!candidate.exists || candidate.registered} onClick={() => run(() => addSource(candidate), "候補を登録しました")}>
              {candidate.registered ? "登録済み" : candidate.exists ? "登録" : "未検出"}
            </button>
          </div>
        ))}
      </div>

      <div className="section-heading compact">
        <h3>登録済み</h3>
      </div>
      <div className="source-list">
        {sources.map((source) => (
          <article key={source.id} className="source-card">
            <div className="source-main">
              <div>
                <h3>{source.name}</h3>
                <p>{source.path}</p>
              </div>
              <span className={`status-dot ${source.enabled ? "on" : ""}`}>{source.enabled ? "有効" : "無効"}</span>
            </div>
            <div className="source-actions">
              <button onClick={() => run(() => api(`/api/sources/${source.id}`, { method: "PATCH", body: JSON.stringify({ enabled: !source.enabled }) }), "状態を更新しました")}>
                {source.enabled ? <Square size={16} /> : <CheckCircle2 size={16} />}
                {source.enabled ? "無効化" : "有効化"}
              </button>
              <button
                className="danger"
                onClick={() => {
                  if (window.confirm("DB上の登録だけを削除します。元ファイルは変更しません。")) {
                    run(() => api(`/api/sources/${source.id}`, { method: "DELETE" }), "登録を削除しました");
                  }
                }}
              >
                <Trash2 size={16} />
                登録削除
              </button>
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}

function ScanScreen({ sources, status, logs, setLogs, onRefresh, onMessage, onError }) {
  const [options, setOptions] = useState(defaultScanOptions);
  const activeSources = useMemo(() => sources.filter((source) => source.enabled), [sources]);
  const elapsed = status?.elapsed_seconds == null ? "-" : `${status.elapsed_seconds}秒`;

  const payload = (dryRun = false) => ({
    max_items: options.max_items ? Number(options.max_items) : null,
    exclude_dirs: splitList(options.exclude_dirs),
    exclude_extensions: splitList(options.exclude_extensions),
    regenerate_thumbnails: options.regenerate_thumbnails,
    hash_mode: options.hash_mode,
    dry_run: dryRun,
  });

  const run = async (fn, message) => {
    onError("");
    try {
      await fn();
      if (message) onMessage(message);
      await onRefresh();
    } catch (err) {
      onError(err.message || String(err));
    }
  };

  return (
    <section className="screen">
      <div className="scan-hero">
        <div>
          <p className="subtle">読み取り専用スキャン</p>
          <h2>{status?.running ? (status?.dry_run ? "見積もり中" : "スキャン中") : "停止中"}</h2>
          <p>{status?.last_message || "待機中"}</p>
        </div>
        <div className={status?.running ? "pulse running" : "pulse"} />
      </div>

      <div className="scan-actions">
        <button className="primary" disabled={status?.running || activeSources.length === 0} onClick={() => run(() => api("/api/scan/start", { method: "POST", body: JSON.stringify(payload(false)) }), "スキャンを開始しました")}>
          <Play size={18} />
          スキャン開始
        </button>
        <button disabled={status?.running || activeSources.length === 0} onClick={() => run(() => api("/api/scan/estimate", { method: "POST", body: JSON.stringify(payload(true)) }), "見積もりを開始しました")}>
          <ListChecks size={18} />
          事前見積もり
        </button>
        <button disabled={!status?.running} onClick={() => run(() => api("/api/scan/cancel", { method: "POST", body: "{}" }), "キャンセルを要求しました")}>
          <Square size={18} />
          キャンセル
        </button>
      </div>

      <div className="metric-grid">
        <Metric label="処理済み" value={status?.processed ?? 0} />
        <Metric label="登録/更新" value={status?.indexed ?? 0} />
        <Metric label="見積もり" value={status?.estimated ?? 0} />
        <Metric label="スキップ" value={status?.skipped ?? 0} />
        <Metric label="エラー" value={status?.errors ?? 0} />
        <Metric label="経過時間" value={elapsed} />
      </div>

      <div className="source-form">
        <h3>大量写真向け安全設定</h3>
        <div className="filter-grid">
          <label>
            スキャン最大件数
            <input type="number" min="0" value={options.max_items} onChange={(event) => setOptions({ ...options, max_items: event.target.value })} placeholder="0 は無制限" />
          </label>
          <label>
            ハッシュ計算
            <select value={options.hash_mode} onChange={(event) => setOptions({ ...options, hash_mode: event.target.value })}>
              <option value="full">SHA-256</option>
              <option value="fast">軽量モード</option>
              <option value="off">OFF</option>
            </select>
          </label>
          <label>
            除外拡張子
            <input value={options.exclude_extensions} onChange={(event) => setOptions({ ...options, exclude_extensions: event.target.value })} placeholder="mov,mp4" />
          </label>
        </div>
        <label>
          除外フォルダ
          <textarea value={options.exclude_dirs} onChange={(event) => setOptions({ ...options, exclude_dirs: event.target.value })} rows={3} />
        </label>
        <label className="check-row">
          <input type="checkbox" checked={options.regenerate_thumbnails} onChange={(event) => setOptions({ ...options, regenerate_thumbnails: event.target.checked })} />
          サムネイルを再生成する
        </label>
      </div>

      <div className="admin-actions">
        <button onClick={() => run(() => api("/api/db/backup", { method: "POST", body: "{}" }), "DBバックアップを作成しました")}>DBバックアップ</button>
        <button
          className="danger"
          onClick={() => {
            if (window.confirm("DBのインデックスをリセットします。元写真は変更しません。")) {
              run(() => api("/api/db/reset", { method: "POST", body: JSON.stringify({ confirm: true, keep_sources: true }) }), "DBインデックスをリセットしました");
            }
          }}
        >
          DBリセット
        </button>
        <button onClick={() => run(async () => setLogs(await api("/api/logs")), "ログを読み込みました")}>ログ表示</button>
      </div>

      {logs && <LogPanel logs={logs.logs} />}

      <div className="info-list">
        <div>
          <span>現在のソース</span>
          <strong>{status?.current_source || "-"}</strong>
        </div>
        <div>
          <span>開始時刻</span>
          <strong>{formatDate(status?.started_at)}</strong>
        </div>
        <div>
          <span>有効ソース数</span>
          <strong>{activeSources.length}</strong>
        </div>
      </div>
    </section>
  );
}

function OcrScreen({ sources, status, stats, onRefresh, onMessage, onError }) {
  const [form, setForm] = useState({ mode: "screenshot", source_id: "", max_items: "100", retry_errors: true, reprocess_done: false, language: "jpn+eng" });
  const capabilities = stats?.ocr_capabilities;
  const run = async (fn, message) => {
    onError("");
    try {
      await fn();
      if (message) onMessage(message);
      await onRefresh();
    } catch (err) {
      onError(err.message || String(err));
    }
  };
  const payload = {
    mode: form.mode,
    source_id: form.source_id ? Number(form.source_id) : null,
    max_items: Number(form.max_items || 100),
    retry_errors: form.retry_errors,
    reprocess_done: form.reprocess_done,
    language: form.language,
  };
  return (
    <section className="screen">
      <div className="scan-hero">
        <div>
          <p className="subtle">ユーザー開始時だけ処理</p>
          <h2>{status?.running ? "OCR処理中" : "OCR検索"}</h2>
          <p>{status?.last_message || "スクショ、書類、看板、領収書、メモ写真の文字をローカルで検索対象にします。"}</p>
        </div>
        <div className={status?.running ? "pulse running" : "pulse"} />
      </div>

      <div className="notice-box">
        <ShieldCheck size={22} />
        <div>
          <strong>写真は外部送信しません</strong>
          <p>{capabilities?.message || "OCR環境を確認中です。"}</p>
          <p>テスト用結果は `data/test_assets` 専用です。実写真OCRにはTesseract OCRと必要な言語データを使います。</p>
        </div>
      </div>

      <div className="source-form">
        <div className="filter-grid">
          <label>
            OCR対象
            <select value={form.mode} onChange={(event) => setForm({ ...form, mode: event.target.value })}>
              <option value="screenshot">スクショのみ</option>
              <option value="all">全件</option>
              <option value="image">画像のみ</option>
              <option value="unprocessed">未処理のみ</option>
              <option value="errors">エラー再処理</option>
            </select>
          </label>
          <label>
            データソース
            <select value={form.source_id} onChange={(event) => setForm({ ...form, source_id: event.target.value })}>
              <option value="">すべて</option>
              {sources.map((source) => (
                <option key={source.id} value={source.id}>
                  {source.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            最大件数
            <input type="number" min="1" max="10000" value={form.max_items} onChange={(event) => setForm({ ...form, max_items: event.target.value })} />
          </label>
          <label>
            OCR言語
            <select value={form.language} onChange={(event) => setForm({ ...form, language: event.target.value })}>
              <option value="jpn+eng">日本語+英語</option>
              <option value="jpn">日本語</option>
              <option value="eng">英語</option>
            </select>
          </label>
        </div>
        <label className="check-row">
          <input type="checkbox" checked={form.retry_errors} onChange={(event) => setForm({ ...form, retry_errors: event.target.checked })} />
          エラー済みも再処理する
        </label>
        <label className="check-row">
          <input type="checkbox" checked={form.reprocess_done} onChange={(event) => setForm({ ...form, reprocess_done: event.target.checked })} />
          OCR済みも再処理する
        </label>
        <p className="helper-text">実写真は元フォルダを直接OCRせず、data\real_test_photos などへコピーした検証用フォルダで、まず最大100〜300件から試してください。</p>
      </div>

      <div className="scan-actions">
        <button className="primary" disabled={status?.running} onClick={() => run(() => api("/api/ocr/start", { method: "POST", body: JSON.stringify(payload) }), "OCRを開始しました")}>
          <ScanLine size={18} />
          OCR開始
        </button>
        <button disabled={!status?.running} onClick={() => run(() => api("/api/ocr/cancel", { method: "POST", body: "{}" }), "OCRキャンセルを要求しました")}>
          <Square size={18} />
          キャンセル
        </button>
      </div>

      <div className="metric-grid">
        <Metric label="対象" value={status?.target_count ?? 0} />
        <Metric label="処理済み" value={status?.processed ?? 0} />
        <Metric label="成功" value={status?.succeeded ?? 0} />
        <Metric label="エラー" value={status?.errors ?? 0} />
        <Metric label="実OCR" value={stats?.ocr_real_done ?? 0} />
        <Metric label="テスト用結果" value={stats?.ocr_test_fallback_done ?? 0} />
        <Metric label="OCR済み" value={stats?.ocr_done ?? 0} />
        <Metric label="未処理" value={stats?.ocr_pending ?? 0} />
      </div>

      <div className="info-list">
        <div>
          <span>現在のファイル</span>
          <strong>{status?.current_file_name || "-"}</strong>
        </div>
        <div>
          <span>OCR方式</span>
          <strong>{ocrEngineLabel(status?.engine || capabilities?.engine)}</strong>
        </div>
        <div>
          <span>OCR言語</span>
          <strong>{ocrLanguageLabel(status?.language || form.language)}</strong>
        </div>
        <div>
          <span>開始時刻</span>
          <strong>{formatDate(status?.started_at)}</strong>
        </div>
      </div>
    </section>
  );
}

function StatsScreen({ stats, duplicateGroups, onOpenDetail, token }) {
  if (!stats) return null;
  return (
    <section className="screen">
      <div className="section-heading">
        <div>
          <h2>統計</h2>
          <p>ローカルDBに登録された件数です。</p>
        </div>
      </div>
      <div className="metric-grid">
        <Metric label="登録ファイル" value={stats.total_items} />
        <Metric label="サムネイル" value={stats.thumbnails} />
        <Metric label="重複グループ" value={stats.duplicate_groups} />
        <Metric label="エラー" value={stats.errors} />
        <Metric label="OCR済み" value={stats.ocr_done} />
        <Metric label="実OCR" value={stats.ocr_real_done ?? 0} />
        <Metric label="テスト用結果" value={stats.ocr_test_fallback_done ?? 0} />
        <Metric label="OCRエラー" value={stats.ocr_errors} />
      </div>
      <div className="source-list">
        {stats.sources.map((source) => (
          <article className="source-card" key={source.id}>
            <div className="source-main">
              <div>
                <h3>{source.name}</h3>
                <p>{source.path}</p>
              </div>
              <span className="count-badge">{source.item_count}件</span>
            </div>
          </article>
        ))}
      </div>
      <div className="split-lists">
        <SmallList title="種類別" rows={stats.by_type} labelKey="media_type" />
        <SmallList title="拡張子別" rows={stats.by_extension} labelKey="extension" />
        <SmallList title="推定カテゴリ別" rows={stats.by_category || []} labelKey="inferred_category" formatter={categoryLabel} />
        <SmallList title="OCR方式別" rows={stats.by_ocr_engine || []} labelKey="ocr_engine" formatter={ocrEngineLabel} />
        <SmallList title="実OCR言語別" rows={stats.by_ocr_language || []} labelKey="ocr_language" formatter={ocrLanguageLabel} />
      </div>
      <div className="notice-box">
        <FileText size={22} />
        <div>
          <strong>OCR / HEIC 状況</strong>
          <p>{stats.ocr_capabilities?.message}</p>
          <p>日本語データ jpn: {stats.ocr_capabilities?.jpn_available ? "利用可" : "未検出"} / 英語 eng: {stats.ocr_capabilities?.eng_available ? "利用可" : "未検出"}</p>
          {stats.ocr_capabilities?.tessdata_dir && <p className="mono">言語データ: {stats.ocr_capabilities.tessdata_dir}</p>}
          <p>{stats.heif?.message}</p>
        </div>
      </div>
      <DuplicateSection groups={duplicateGroups} onOpenDetail={onOpenDetail} token={token} />
    </section>
  );
}

function DuplicateSection({ groups, onOpenDetail, token }) {
  return (
    <section className="screen">
      <div className="section-heading">
        <div>
          <h2>重複候補</h2>
          <p>同じハッシュを持つファイルです。ここから削除や移動はできません。</p>
        </div>
      </div>
      {!groups.length && (
        <div className="empty-state">
          <Database size={40} />
          <h3>重複候補はまだありません</h3>
          <p>サンプルをスキャンすると、同一内容のサンプル画像が候補として表示されます。</p>
        </div>
      )}
      <div className="duplicate-list">
        {groups.map((group) => (
          <article className="duplicate-group" key={group.file_hash}>
            <header>
              <strong>{group.count}件の候補</strong>
              <span>{formatBytes(group.total_size)}</span>
            </header>
            <ResultGrid items={group.items} onOpenDetail={onOpenDetail} token={token} />
          </article>
        ))}
      </div>
    </section>
  );
}

function HelpScreen({ apiBase, stats, accessMode }) {
  const isLanMode = accessMode === "lan";
  const phoneUrl = `${window.location.protocol}//${window.location.hostname}:${window.location.port || "5173"}`;
  return (
    <section className="screen help">
      <div className="section-heading">
        <div>
          <h2>しまい箱の使い方</h2>
          <p>同期済み写真フォルダを、PC内または家庭内LANで探しやすくするためのローカルツールです。</p>
        </div>
      </div>
      <article className="privacy-note">
        <ShieldCheck size={22} />
        <div>
          <h3>しまい箱でできること</h3>
          <p>iCloud写真、OneDrive写真、任意フォルダを横断検索できます。写真内文字は、ユーザーがOCR開始を押した場合だけローカルで処理します。</p>
          <ul className="plain-list">
            <li>写真は外部送信しません。</li>
            <li>読み取り専用で、元写真の削除・移動・リネーム・上書きはしません。</li>
            <li>スマホから使う時は、起動時に表示されるPINが必要です。</li>
            <li>実写真はまずコピーした小規模フォルダで、最大100〜300件から試してください。</li>
          </ul>
        </div>
      </article>
      <article>
        <h3>サンプルで試す</h3>
        <p>初回はサンプル写真が登録されています。スキャン画面でスキャンし、検索画面で `tokyo`、`Receipt`、`Screenshot` などを検索できます。</p>
      </article>
      <article>
        <h3>実写真を試す前に</h3>
        <p>`data/real_test_photos` または任意の検証用フォルダに、元写真のコピーだけを入れてからデータソースに追加してください。最初は100〜300件程度に絞ると、OCRやサムネイルの確認が安全にできます。</p>
      </article>
      <article>
        <h3>スマホから開く</h3>
        <p>PCとiPhoneを同じ家庭内Wi-Fiに接続し、起動スクリプトに表示された `http://192.168.x.x:ポート番号` をSafariで開きます。</p>
        {isLanMode ? (
          <>
            <p className="mono">{phoneUrl}</p>
            <p>PIN入力後に利用できます。信頼できる家庭内Wi-Fiでのみ使い、公共Wi-Fiや会社Wi-Fiでは使わないでください。</p>
          </>
        ) : (
          <p>現在はLocalOnlyモードです。スマホURLは表示しません。スマホから使う場合だけ起動時に -LanAccess を指定してください。</p>
        )}
      </article>
      <article className="privacy-note">
        <Wifi size={22} />
        <div>
          <h3>つながらない時</h3>
          <p>Windows Firewallで Python または Node.js の許可が必要な場合があります。公共Wi-Fi、会社Wi-Fi、外部公開、ポート開放、トンネル公開では使わないでください。</p>
        </div>
      </article>
      <article className="privacy-note">
        <ShieldCheck size={22} />
        <div>
          <h3>安全方針</h3>
          <p>写真本体やメタデータを外部送信しません。外部クラウドAPIには接続しません。元写真の削除、移動、リネーム、上書きはしません。</p>
        </div>
      </article>
      <article>
        <h3>OCR / HEIC / 動画</h3>
        <p>{stats?.ocr_capabilities?.message || "OCR環境を確認中です。"}</p>
        <p>{stats?.heif?.message || "HEIC対応状況を確認中です。"}</p>
        <p>動画サムネイルはローカルの ffmpeg がある場合だけ代表フレーム生成を試します。無い場合はプレースホルダー表示です。</p>
      </article>
      <article>
        <h3>接続先API</h3>
        <p className="mono">{apiBase}</p>
      </article>
    </section>
  );
}

function DetailModal({ item, onClose, onMessage, token }) {
  if (!item) return null;
  const copyPath = async () => {
    await navigator.clipboard.writeText(item.file_path);
    onMessage("パスをコピーしました");
  };
  return (
    <div className="modal-backdrop" role="dialog" aria-modal="true">
      <div className="detail-modal">
        <header>
          <h2>{item.file_name}</h2>
          <button className="icon-button" onClick={onClose} aria-label="閉じる">
            <X size={20} />
          </button>
        </header>
        <img className="detail-thumb" src={thumbnailUrl(item.id, token)} alt="" />
        <div className="detail-actions">
          <button onClick={copyPath}>
            <Copy size={18} />
            元パスをコピー
          </button>
        </div>
        <dl className="detail-list">
          <div>
            <dt>データソース</dt>
            <dd>{item.source_name}</dd>
          </div>
          <div>
            <dt>種類</dt>
            <dd>{item.media_type === "video" ? "動画" : "画像"}</dd>
          </div>
          <div>
            <dt>推定カテゴリ</dt>
            <dd>{categoryLabel(item.inferred_category)}</dd>
          </div>
          <div>
            <dt>OCR状態</dt>
            <dd>{ocrStatusLabel(item.ocr_status, item.ocr_engine)}</dd>
          </div>
          <div>
            <dt>OCR方式</dt>
            <dd>{ocrEngineLabel(item.ocr_engine)}</dd>
          </div>
          <div>
            <dt>OCR言語</dt>
            <dd>{ocrLanguageLabel(item.ocr_language)}</dd>
          </div>
          <div>
            <dt>撮影日</dt>
            <dd>{formatDate(item.taken_at)}</dd>
          </div>
          <div>
            <dt>更新日</dt>
            <dd>{formatDate(item.modified_at)}</dd>
          </div>
          <div>
            <dt>サイズ</dt>
            <dd>{formatBytes(item.size_bytes)}</dd>
          </div>
          <div>
            <dt>解像度</dt>
            <dd>{item.width && item.height ? `${item.width} x ${item.height}` : "-"}</dd>
          </div>
          <div>
            <dt>拡張子</dt>
            <dd>{item.extension}</dd>
          </div>
          <div className="full">
            <dt>OCRテキスト</dt>
            <dd className="ocr-text">
              {item.ocr_text || item.ocr_error || "未処理です"}
              {item.ocr_engine === "test_asset_fallback" && <span className="inline-note">これは data/test_assets 専用のテスト用結果です。</span>}
            </dd>
          </div>
          <div className="full">
            <dt>元パス</dt>
            <dd className="path-text">{item.file_path}</dd>
          </div>
          <div className="full">
            <dt>ハッシュ</dt>
            <dd className="path-text">{item.file_hash || "-"}</dd>
          </div>
        </dl>
      </div>
    </div>
  );
}

function InfoBox({ title, text }) {
  return (
    <article className="info-box">
      <strong>{title}</strong>
      <p>{text}</p>
    </article>
  );
}

function Metric({ label, value }) {
  return (
    <div className="metric">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function SmallList({ title, rows, labelKey, formatter = (value) => value }) {
  return (
    <article className="small-list">
      <h3>{title}</h3>
      {rows.length === 0 && <p>データなし</p>}
      {rows.map((row) => (
        <div key={row[labelKey]}>
          <span>{formatter(row[labelKey])}</span>
          <strong>{row.count}</strong>
        </div>
      ))}
    </article>
  );
}

function LogPanel({ logs }) {
  return (
    <div className="log-panel">
      {Object.entries(logs || {}).map(([name, lines]) => (
        <details key={name}>
          <summary>{name}</summary>
          <pre>{lines.join("\n")}</pre>
        </details>
      ))}
    </div>
  );
}

function splitList(value) {
  return String(value || "")
    .split(/[,\n]/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function ocrStatusLabel(status, engine) {
  if (status === "done" && engine === "test_asset_fallback") return "テスト用結果";
  if (status === "done" && engine === "sample_fallback") return "サンプル用結果";
  if (status === "done") return "OCR済み";
  if (status === "processing") return "処理中";
  if (status === "error") return "読取エラー";
  if (status === "skipped") return "スキップ";
  return "未処理";
}

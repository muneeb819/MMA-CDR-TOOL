import { useEffect, useState } from "react";
import { Activity, Database, FileUp, Gauge, Radio, ScanSearch, ShieldCheck, Zap } from "lucide-react";
import { api } from "./lib/api";
import { logAction } from "./lib/usage";

const DEFAULT_TENANT = "00000000-0000-0000-0000-000000000001";
const tabs = [
  ["overview", "Overview", Activity],
  ["scrubber", "Scrubber Upload", FileUp],
  ["refine", "Refine & Score", ScanSearch],
  ["telemetry", "Telemetry", Radio],
  ["database", "Database / SSMS", Database],
] as const;

type Tab = (typeof tabs)[number][0];

export default function App() {
  const [tab, setTab] = useState<Tab>("overview");
  const goTab = (t: Tab) => { setTab(t); logAction("tab_switch", { tab: t }); };
  const [health, setHealth] = useState<any>(null);
  const [uploads, setUploads] = useState<any[]>([]);
  const [telemetry, setTelemetry] = useState<any[]>([]);
  const [notice, setNotice] = useState("");
  const [online, setOnline] = useState(false);

  async function refresh() {
    try {
      const h = await api.health();
      setHealth(h);
      setOnline(h.status === "ok");
      const [u, t] = await Promise.allSettled([api.recentUploads(10), api.recentTelemetry(10)]);
      if (u.status === "fulfilled") setUploads(u.value.items || []);
      if (t.status === "fulfilled") setTelemetry(t.value.items || []);
    } catch (e: any) {
      setOnline(false);
      setNotice("API offline — running in demo mode. Start backend: uvicorn api.app:app --port 8000");
    }
  }

  useEffect(() => { refresh(); const i = setInterval(refresh, 15000); return () => clearInterval(i); }, []);

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100">
      <header className="sticky top-0 z-40 border-b border-white/10 bg-slate-950/90 backdrop-blur">
        <div className="mx-auto flex max-w-7xl items-center justify-between px-4 py-3">
          <div className="flex items-center gap-3">
            <span className="grid h-10 w-10 place-items-center rounded-2xl bg-amber-400 text-slate-950"><Zap size={20} /></span>
            <div>
              <b className="text-lg tracking-tight">MMA-CDR TOOL</b>
              <p className="text-[11px] text-slate-400">CDR Intelligence & Refinement · SQL Server edition</p>
            </div>
          </div>
          <div className="flex items-center gap-2 text-xs">
            <span className={`rounded-full px-3 py-1.5 font-bold ${online ? "bg-emerald-500/15 text-emerald-300" : "bg-amber-500/15 text-amber-300"}`}>
              {online ? `● LIVE · ${health?.database}` : "○ DEMO MODE"}
            </span>
            <span className="hidden rounded-full bg-white/5 px-3 py-1.5 text-slate-300 md:block">{api.base}</span>
          </div>
        </div>
        <nav className="mx-auto flex max-w-7xl gap-1 overflow-x-auto px-4 pb-3">
          {tabs.map(([id, label, Icon]) => (
            <button key={id} onClick={() => goTab(id)}
              className={`flex items-center gap-2 whitespace-nowrap rounded-xl px-4 py-2.5 text-sm font-bold ${tab === id ? "bg-amber-400 text-slate-950" : "bg-white/5 text-slate-300 hover:bg-white/10"}`}>
              <Icon size={16} />{label}
            </button>
          ))}
        </nav>
      </header>

      {notice && <div className="mx-auto mt-3 max-w-7xl px-4"><div className="rounded-2xl bg-amber-400/10 p-3 text-sm text-amber-200">{notice}</div></div>}

      <main className="mx-auto max-w-7xl px-4 pb-20 pt-6">
        {tab === "overview" && <Overview health={health} uploads={uploads} telemetry={telemetry} online={online} go={goTab} />}
        {tab === "scrubber" && <Scrubber onDone={refresh} />}
        {tab === "refine" && <Refine />}
        {tab === "telemetry" && <TelemetryPanel onSent={refresh} />}
        {tab === "database" && <DatabasePanel />}
      </main>
    </div>
  );
}

function Card({ title, sub, children }: any) {
  return <section className="rounded-3xl border border-white/10 bg-white/[0.04] p-5">
    <h2 className="font-black">{title}</h2>{sub && <p className="mt-1 text-sm text-slate-400">{sub}</p>}
    <div className="mt-4">{children}</div>
  </section>;
}

function Overview({ health, uploads, telemetry, online, go }: any) {
  return <div className="space-y-4">
    <div className="rounded-3xl bg-gradient-to-br from-amber-400 to-orange-500 p-6 text-slate-950 md:p-8">
      <b className="text-2xl md:text-4xl">Scrub lists. Score leads.<br />Watch VICIdial live.</b>
      <p className="mt-2 max-w-2xl text-sm font-medium">Universal upload (CSV XLS XLSX PDF DOCX JSON XML Parquet ZIP images) → raw staging → refinery normalize/validate/fingerprint/dedupe → SQL Server decisions + telemetry.</p>
      <div className="mt-4 flex flex-wrap gap-2">
        <button onClick={() => go("scrubber")} className="rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-black text-white">Upload a list</button>
        <button onClick={() => go("telemetry")} className="rounded-xl bg-white/80 px-4 py-2.5 text-sm font-black">Send telemetry</button>
        <span className="rounded-xl bg-slate-950/10 px-4 py-2.5 text-sm font-bold">Backend: {health?.database || "offline"}</span>
      </div>
    </div>
    <div className="grid gap-4 md:grid-cols-4">
      {[["API status", health?.status?.toUpperCase() || "OFFLINE", Activity], ["Database", health?.database || "—", Database],
        ["Uploads tracked", String(uploads.length), FileUp], ["Telemetry frames", String(telemetry.length), Gauge]].map(([a, b, I]: any) => (
        <div key={a} className="rounded-3xl border border-white/10 bg-white/[0.04] p-4"><I size={18} className="text-amber-300" />
          <p className="mt-4 text-xs text-slate-400">{a}</p><b className="text-xl">{b}</b></div>
      ))}
    </div>
    <div className="grid gap-4 md:grid-cols-2">
      <Card title="Recent uploads" sub={online ? "From SQL Server / SQLite" : "Demo — connect API for live rows"}>
        {!uploads.length ? <Empty t="No uploads yet" s="Go to Scrubber Upload and drop any file." /> :
          <ul className="space-y-2 text-sm">{uploads.map((u: any, i: number) => (
            <li key={i} className="flex justify-between gap-3 rounded-xl bg-white/5 p-3"><span className="truncate">{u.original_file_name || u.file_name || u.upload_batch_id}</span><b className="text-amber-300">{u.extracted_phone_count ?? u.phone_candidates ?? "—"}</b></li>))}</ul>}
      </Card>
      <Card title="Recent telemetry" sub="Drop %, queue, agent state">
        {!telemetry.length ? <Empty t="No telemetry yet" s="Use Telemetry tab or VICIdial extension." /> :
          <ul className="space-y-2 text-sm">{telemetry.map((t: any, i: number) => (
            <li key={i} className="flex justify-between rounded-xl bg-white/5 p-3"><span>drop {t.drop_percent}% · queue {t.calls_in_queue}</span><span className="text-slate-400">{t.source_url?.slice(0, 32)}</span></li>))}</ul>}
      </Card>
    </div>
    {!online && <Card title="Quick start" sub="3 steps to go live">
      <ol className="list-decimal space-y-1 pl-5 text-sm text-slate-300">
        <li>Run <code>database/mma-cdr-sqlserver.sql</code> in SSMS → creates <code>CDR_Intelligence</code>.</li>
        <li>Copy <code>.env.example</code> to <code>.env</code>, set SQLSERVER_* + <code>pip install -r api/requirements.txt</code>.</li>
        <li><code>uvicorn api.app:app --port 8000</code> then set <code>VITE_API_URL</code> and <code>npm run dev</code>.</li>
      </ol>
    </Card>}
  </div>;
}

function Scrubber({ onDone }: any) {
  const [file, setFile] = useState<File | null>(null);
  const [tenant, setTenant] = useState(DEFAULT_TENANT);
  const [campaign, setCampaign] = useState("");
  const [out, setOut] = useState<any>(null);
  const [busy, setBusy] = useState(false);
  async function send() {
    if (!file) return alert("Select a file first — any extension is accepted.");
    setBusy(true); setOut(null);
    try { const r = await api.upload(file, tenant, campaign || undefined); setOut(r); onDone(); logAction("scrubber_upload_click", { file: file.name, tenant }, r); }
    catch (e: any) { const err = { ok: false, error: e.message }; setOut(err); logAction("scrubber_upload_click", { file: file.name }, err); }
    finally { setBusy(false); }
  }
  return <div className="grid gap-4 md:grid-cols-2">
    <Card title="Universal scrubber upload" sub="Any file extension / MIME accepted. Known formats parsed, unknown binaries retained as evidence.">
      <input type="file" accept="*/*" onChange={e => setFile(e.target.files?.[0] || null)}
        className="w-full rounded-2xl border-2 border-dashed border-white/15 bg-white/5 p-6 text-sm" />
      <input value={tenant} onChange={e => setTenant(e.target.value)} placeholder="Tenant GUID" className="mt-3 w-full rounded-xl bg-white/5 p-3 text-sm outline-none" />
      <input value={campaign} onChange={e => setCampaign(e.target.value)} placeholder="Campaign GUID (optional)" className="mt-2 w-full rounded-xl bg-white/5 p-3 text-sm outline-none" />
      <button onClick={send} disabled={busy} className="mt-3 w-full rounded-xl bg-amber-400 py-3 font-black text-slate-950 disabled:opacity-50">{busy ? "Extracting…" : "Upload & Extract"}</button>
      <p className="mt-2 text-xs text-slate-400">CSV TSV TXT LOG JSON XML HTML XLSX XLS XLSB ODS Parquet PDF DOCX ZIP images + OCR. Max {256} MB (MAX_UPLOAD_MB).</p>
    </Card>
    <Card title="Result" sub="Phone candidates → raw_records → Rust refinery → decisions">
      {!out ? <Empty t="No upload yet" s="Result JSON appears here." /> : <pre className="max-h-[480px] overflow-auto rounded-2xl bg-black/40 p-4 text-xs leading-5">{JSON.stringify(out, null, 2)}</pre>}
    </Card>
  </div>;
}

function Refine() {
  const [phone, setPhone] = useState("+1 (415) 555-0132");
  const [out, setOut] = useState<any>(null);
  const [busy, setBusy] = useState(false);
  async function run() {
    setBusy(true);
    try {
      const [r, s] = await Promise.all([api.refine({ phone }), api.score({ phone, freshness_days: 20, attempts: 5, answered: 2 })]);
      const combined = { refine: r, score: s };
      setOut(combined); logAction("refine_score_click", { phone }, combined);
    } catch (e: any) { const err = { error: e.message }; setOut(err); logAction("refine_score_click", { phone }, err); }
    finally { setBusy(false); }
  }
  return <div className="grid gap-4 md:grid-cols-2">
    <Card title="Normalize · Fingerprint · Score" sub="Python inline refinery mirrors Rust: normalize → fingerprint → dedupe → suppression → score.">
      <input value={phone} onChange={e => setPhone(e.target.value)} className="w-full rounded-xl bg-white/5 p-3 font-mono text-sm outline-none" />
      <button onClick={run} disabled={busy} className="mt-3 w-full rounded-xl bg-amber-400 py-3 font-black text-slate-950 disabled:opacity-50">{busy ? "Scoring…" : "Refine + Score"}</button>
      <div className="mt-3 flex items-center gap-2 text-xs text-slate-400"><ShieldCheck size={14} /> Decisions: CALL / REVIEW / SUPPRESS / INVALID / DUPLICATE. Area code is a signal, not proof of location.</div>
    </Card>
    <Card title="Decision" sub="quality · contactability · risk · compliance">
      {!out ? <Empty t="No score yet" s="Enter a phone and run." /> : <pre className="max-h-[480px] overflow-auto rounded-2xl bg-black/40 p-4 text-xs leading-5">{JSON.stringify(out, null, 2)}</pre>}
    </Card>
  </div>;
}

function TelemetryPanel({ onSent }: any) {
  const [form, setForm] = useState({ source_url: "https://vicidial.local/agc/vicidial.php", agents_logged_in: 12, agents_in_call: 8, agents_waiting: 0, agents_paused: 2, calls_in_queue: 5, drop_percent: 4.2, campaign_id: "" });
  const [out, setOut] = useState<any>(null);
  const [summary, setSummary] = useState<any>(null);
  const set = (k: string, v: any) => setForm(f => ({ ...f, [k]: v }));
  async function send() {
    try {
      const r = await api.telemetry({ timestamp: new Date().toISOString(), tenant_id: DEFAULT_TENANT, ...form, campaign_id: form.campaign_id || undefined });
      setOut(r); onSent(); logAction("telemetry_send_click", form, r);
    } catch (e: any) { const err = { error: e.message }; setOut(err); logAction("telemetry_send_click", form, err); }
  }
  return <div className="grid gap-4 md:grid-cols-2">
    <Card title="Send telemetry frame" sub="Same contract as extension + WS /ws/v2/vici">
      {Object.entries(form).map(([k, v]) => (
        <label key={k} className="mb-2 block text-xs text-slate-400">{k}
          <input value={v} onChange={e => set(k, k.includes("url") || k.includes("campaign") ? e.target.value : Number(e.target.value))}
            className="mt-1 w-full rounded-xl bg-white/5 p-2.5 text-sm text-white outline-none" /></label>
      ))}
      <button onClick={send} className="mt-2 w-full rounded-xl bg-amber-400 py-3 font-black text-slate-950">Analyze + Persist</button>
      <div className="mt-2 flex gap-2">
        <input id="cs" placeholder="Campaign GUID for summary" className="flex-1 rounded-xl bg-white/5 p-2.5 text-sm outline-none" />
        <button onClick={async () => { const v = (document.getElementById("cs") as HTMLInputElement).value; if (v) { const s = await api.campaignSummary(v); setSummary(s); logAction("campaign_summary_click", { campaign_id: v }, s); } }}
          className="rounded-xl bg-white/10 px-4 text-sm font-bold">Summary</button>
      </div>
      {summary && <pre className="mt-2 rounded-xl bg-black/40 p-3 text-xs">{JSON.stringify(summary, null, 2)}</pre>}
    </Card>
    <Card title="AI insights" sub="Drop anomaly · queue saturation · paused ratio">
      {!out ? <Empty t="No frame sent" s="Alerts appear here." /> : <pre className="max-h-[560px] overflow-auto rounded-2xl bg-black/40 p-4 text-xs leading-5">{JSON.stringify(out, null, 2)}</pre>}
    </Card>
  </div>;
}

function DatabasePanel() {
  return <div className="grid gap-4 md:grid-cols-2">
    <Card title="SSMS setup (authoritative)" sub="SQL Server 2012+ is the single persistence layer">
      <ol className="list-decimal space-y-2 pl-5 text-sm text-slate-300">
        <li>Open SSMS → connect to instance.</li>
        <li>Open <code>database/mma-cdr-sqlserver.sql</code> → Execute → creates <code>CDR_Intelligence</code> + 16 tables, 11 procs, 5 views.</li>
        <li>Create least-privilege login:<pre className="mt-1 rounded-xl bg-black/40 p-3 text-xs">USE [CDR_Intelligence];{"\n"}CREATE USER [cdr_app] FOR LOGIN [cdr_app];{"\n"}ALTER ROLE [db_datareader] ADD MEMBER [cdr_app];{"\n"}ALTER ROLE [db_datawriter] ADD MEMBER [cdr_app];{"\n"}GRANT EXECUTE TO [cdr_app];</pre></li>
        <li>Set <code>.env</code> from <code>.env.example</code>. Install ODBC Driver 18.</li>
      </ol>
    </Card>
    <Card title="Objects" sub="What the script creates">
      <ul className="grid grid-cols-2 gap-2 text-xs">
        {["tenants", "campaigns", "upload_batches", "upload_files", "raw_records", "phone_numbers", "leads", "calls", "suppressions", "verifications", "decisions", "telemetry_snapshots", "alerts", "audit_logs", "source_quality_daily", "processing_jobs"].map(t => (
          <li key={t} className="rounded-xl bg-white/5 px-3 py-2 font-mono">{t}</li>))}
      </ul>
      <p className="mt-3 text-xs text-slate-400">Views: vw_latest_phone_verification · vw_active_suppressions · vw_upload_summary · vw_campaign_telemetry_latest · vw_cdr_decision_summary</p>
      <p className="mt-1 text-xs text-slate-400">Dev fallback: set <code>MMA_CDR_USE_SQLITE=1</code> to run without SQL Server (local <code>mma-cdr.db</code>).</p>
    </Card>
  </div>;
}

function Empty({ t, s }: any) {
  return <div className="rounded-2xl border border-dashed border-white/15 p-8 text-center"><b>{t}</b><p className="mt-1 text-sm text-slate-400">{s}</p></div>;
}

// Use same-origin relative URLs by default. Vite proxies /api, /health and /ws
// to the backend, so preview browsers never try to reach the sandbox via localhost.
const BASE = ((import.meta as any).env?.VITE_API_URL || "").replace(/\/$/, "");

async function req(path: string, init?: RequestInit) {
  const r = await fetch(BASE + path, init);
  const text = await r.text();
  let data: any = text;
  try { data = JSON.parse(text); } catch { /* keep text */ }
  if (!r.ok) throw new Error(typeof data === "string" ? data : data?.detail || `HTTP ${r.status}`);
  return data;
}

export const api = {
  base: BASE,
  health: () => req("/health"),
  telemetry: (body: any) => req("/api/v2/telemetry", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }),
  campaignSummary: (id: string) => req(`/api/v2/campaigns/${encodeURIComponent(id)}/summary`),
  recentTelemetry: (limit = 20) => req(`/api/v2/telemetry/recent?limit=${limit}`),
  recentUploads: (limit = 20) => req(`/api/v2/uploads/recent?limit=${limit}`),
  refine: (body: any) => req("/api/v2/refine", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }),
  score: (body: any) => req("/api/v2/score", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }),
  upload: (file: File, tenant_id: string, campaign_id?: string) => {
    const f = new FormData();
    f.append("file", file);
    f.append("tenant_id", tenant_id);
    if (campaign_id) f.append("campaign_id", campaign_id);
    return req("/api/v2/scrubber/upload", { method: "POST", body: f });
  },
};

export async function logAction(action: string, detail?: any, result?: any) {
  const base = ((import.meta as any).env?.VITE_API_URL || "").replace(/\/$/, "");
  const line = { action, detail: detail ?? {}, result: result ?? {} };
  try {
    await fetch(base + "/api/v2/client-log", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(line),
    });
  } catch {
    /* logging must never break the UI */
  }
  console.debug("[mma-cdr]", action, detail, result);
}

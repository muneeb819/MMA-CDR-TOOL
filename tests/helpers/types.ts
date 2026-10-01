export type PhoneUploadResult = {
  ok: boolean;
  upload_batch_id: string;
  file_name: string;
  extension: string;
  mime_type: string;
  parser: string;
  rows_scanned: number;
  phone_candidates: number;
  sample: string[];
};

export type ScoreResponse = {
  decision: 'CALL' | 'REVIEW' | 'SUPPRESS' | 'INVALID' | 'DUPLICATE';
  quality_score: number;
  contactability_score: number;
  risk_score: number;
  compliance_status: string;
  confidence: number;
  reasons: string[];
  ruleset_version: string;
  model_version: string;
  normalized_phone?: string | null;
  fingerprint?: string;
};

export type TelemetryPayload = {
  timestamp: string;
  tenant_id?: string;
  campaign_id?: string;
  source_url: string;
  agents_logged_in: number;
  agents_in_call: number;
  agents_waiting: number;
  agents_paused: number;
  calls_in_queue: number;
  drop_percent: number;
  dial_level?: number | null;
  raw?: Record<string, unknown>;
};

export type TelemetryResult = {
  status: 'HEALTHY' | 'ACTION_REQUIRED';
  efficiency_score: number;
  utilization_percent: number;
  historical_drop_baseline: number;
  alerts: Array<{ severity: string; type: string; message: string }>;
  observed_at: number;
  persist_warning?: string;
};

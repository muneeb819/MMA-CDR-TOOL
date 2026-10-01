use axum::{extract::State, routing::{get, post}, Json, Router};
use dashmap::DashSet;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{net::SocketAddr, sync::Arc};

const F_MALFORMED: u32 = 1 << 0;
const F_DNC: u32 = 1 << 1;
const F_DUPLICATE: u32 = 1 << 2;

#[derive(Clone)]
struct AppState {
    dnc: Arc<DashSet<String>>,
    seen: Arc<DashSet<String>>,
}

#[derive(Debug, Deserialize)]
struct Lead {
    lead_id: String,
    phone: String,
    duration_seconds: Option<u32>,
}

#[derive(Debug, Serialize)]
struct ResultRow {
    lead_id: String,
    phone: String,
    normalized_phone: Option<String>,
    flags: u32,
    decision: String,
    reasons: Vec<String>,
}

fn normalize_us_phone(input: &str) -> Option<String> {
    let digits: String = input.chars().filter(|c| c.is_ascii_digit()).collect();
    let digits = if digits.len() == 11 && digits.starts_with('1') {
        digits
    } else if digits.len() == 10 {
        format!("1{digits}")
    } else {
        return None;
    };
    Some(format!("+{digits}"))
}

fn fingerprint(e164: &str) -> String {
    let mut h = Sha256::new();
    h.update(e164.as_bytes());
    format!("{:x}", h.finalize())
}

fn process(lead: Lead, state: &AppState) -> ResultRow {
    let mut flags = 0;
    let mut reasons = Vec::new();
    let normalized = normalize_us_phone(&lead.phone);

    if normalized.is_none() {
        flags |= F_MALFORMED;
        reasons.push("Phone normalization failed".to_string());
    }

    if let Some(ref e164) = normalized {
        let fp = fingerprint(e164);
        if state.dnc.contains(&fp) {
            flags |= F_DNC;
            reasons.push("Suppression match".to_string());
        }
        if !state.seen.insert(fp) {
            flags |= F_DUPLICATE;
            reasons.push("Duplicate within processing scope".to_string());
        }
    }

    if let Some(d) = lead.duration_seconds {
        if d < 6 {
            reasons.push("Short-duration event; requires disposition-aware interpretation".to_string());
        }
    }

    let decision = if flags & F_DNC != 0 {
        "SUPPRESS"
    } else if flags & F_DUPLICATE != 0 {
        "DUPLICATE"
    } else if flags & F_MALFORMED != 0 {
        "INVALID"
    } else {
        "PASS"
    };

    ResultRow {
        lead_id: lead.lead_id,
        phone: lead.phone,
        normalized_phone: normalized,
        flags,
        decision: decision.to_string(),
        reasons,
    }
}

async fn health() -> &'static str { "ok" }

async fn refine(
    State(state): State<AppState>,
    Json(lead): Json<Lead>,
) -> Json<ResultRow> {
    Json(process(lead, &state))
}


#[derive(Debug, Deserialize)]
struct BatchRequest {
    records: Vec<Lead>,
}

#[derive(Debug, Serialize)]
struct BatchResponse {
    results: Vec<ResultRow>,
}

async fn refine_batch(State(state): State<AppState>, Json(req): Json<BatchRequest>) -> Json<BatchResponse> {
    let mut results = Vec::with_capacity(req.records.len());
    for lead in req.records {
        results.push(process(lead, &state));
    }
    Json(BatchResponse { results })
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    let state = AppState {
        dnc: Arc::new(DashSet::new()),
        seen: Arc::new(DashSet::new()),
    };

    // Production: populate DNC/suppression data from the authoritative tenant-scoped store.
    let app = Router::new()
        .route("/health", get(health))
        .route("/v2/refine", post(refine))
        .route("/v2/refine/batch", post(refine_batch))
        .with_state(state);

    let addr: SocketAddr = "0.0.0.0:9100".parse().unwrap();
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

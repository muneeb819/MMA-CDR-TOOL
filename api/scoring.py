from dataclasses import dataclass
from datetime import datetime, timezone
from hashlib import sha256
from typing import Any

@dataclass
class HistoricalStats:
    attempts: int = 0
    answered: int = 0
    transferred: int = 0
    sales: int = 0
    dnc_events: int = 0
    wrong_numbers: int = 0
    last_seen: datetime | None = None

def score_record(
    *,
    valid: bool,
    suppressed: bool,
    duplicate: bool,
    reachable: bool | None,
    freshness_days: float,
    stats: HistoricalStats,
    risk_signals: list[str] | None = None,
) -> dict[str, Any]:
    reasons: list[str] = []
    risk_signals = risk_signals or []

    if not valid:
        return {
            "decision": "INVALID",
            "quality_score": 0,
            "contactability_score": 0,
            "risk_score": 0,
            "compliance_status": "UNKNOWN",
            "confidence": 0.99,
            "reasons": ["Structural phone validation failed"],
            "ruleset_version": "2.0.0",
            "model_version": "baseline-2.0.0",
        }

    if duplicate:
        return {
            "decision": "DUPLICATE",
            "quality_score": 20,
            "contactability_score": 0,
            "risk_score": 0,
            "compliance_status": "REVIEW",
            "confidence": 0.99,
            "reasons": ["Duplicate detected"],
            "ruleset_version": "2.0.0",
            "model_version": "baseline-2.0.0",
        }

    if suppressed:
        return {
            "decision": "SUPPRESS",
            "quality_score": 0,
            "contactability_score": 0,
            "risk_score": 0,
            "compliance_status": "SUPPRESS",
            "confidence": 0.99,
            "reasons": ["Suppression/compliance match"],
            "ruleset_version": "2.0.0",
            "model_version": "baseline-2.0.0",
        }

    quality = 100.0
    contact = 50.0
    risk = min(100.0, len(risk_signals) * 12.0)

    if reachable is False:
        quality -= 25
        contact -= 30
        reasons.append("Provider indicates not reachable")
    elif reachable is True:
        quality += 0
        contact += 25
        reasons.append("Provider indicates reachable")

    if freshness_days > 365:
        quality -= 30
        reasons.append("Data is older than one year")
    elif freshness_days > 180:
        quality -= 15
        reasons.append("Data is aging")

    if stats.attempts:
        answer_rate = stats.answered / stats.attempts
        transfer_rate = stats.transferred / stats.attempts
        contact += min(25, answer_rate * 25)
        quality += min(10, answer_rate * 10)
        if answer_rate == 0 and stats.attempts >= 10:
            reasons.append("No successful contacts across repeated historical attempts")
            contact -= 20
        if transfer_rate > 0:
            reasons.append("Historical transfer activity exists")

    if risk_signals:
        reasons.extend(f"Risk signal: {x}" for x in risk_signals)

    quality = max(0, min(100, quality))
    contact = max(0, min(100, contact))
    decision = "CALL" if quality >= 70 and contact >= 55 else "REVIEW"

    return {
        "decision": decision,
        "quality_score": round(quality, 2),
        "contactability_score": round(contact, 2),
        "risk_score": round(risk, 2),
        "compliance_status": "PASS",
        "confidence": 0.75,
        "reasons": reasons or ["No material negative signals"],
        "ruleset_version": "2.0.0",
        "model_version": "baseline-2.0.0",
    }

def phone_fingerprint(e164: str) -> str:
    return sha256(e164.encode()).hexdigest()
